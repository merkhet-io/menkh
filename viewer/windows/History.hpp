#pragma once
// Existing menkh-voxel-history-v1 reader. Independent of Zig and graphics APIs.
#include "vendor/json.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>
namespace menkh {
namespace fs = std::filesystem;
using Json = nlohmann::json;
using Vec = std::array<float, 3>;
constexpr uint32_t Empty = 0xffffffffu, Full = 0xfffffffeu;
inline void require(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
inline std::vector<uint8_t> read(const fs::path &path, size_t limit = size_t(1) << 30) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f)
        throw std::runtime_error("Cannot open " + path.u8string());
    const auto end = f.tellg();
    require(end >= 0 && uint64_t(end) <= limit, "Input file too large");
    std::vector<uint8_t> bytes(static_cast<size_t>(end));
    f.seekg(0);
    if (!bytes.empty())
        f.read(reinterpret_cast<char *>(bytes.data()), std::streamsize(bytes.size()));
    require(bool(f), "Cannot read complete file");
    return bytes;
}
inline uint32_t u32(const uint8_t *p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
inline uint64_t u64(const uint8_t *p) { return uint64_t(u32(p)) | (uint64_t(u32(p + 4)) << 32); }
inline unsigned pop(uint64_t x) {
    x -= (x >> 1) & 0x5555555555555555ull;
    x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
    return unsigned((((x + (x >> 4)) & 0x0f0f0f0f0f0f0f0full) * 0x0101010101010101ull) >> 56);
}
inline Vec vec(const Json &j) {
    require(j.is_array() && j.size() == 3, "Expected 3-vector");
    Vec v{};
    for (size_t i = 0; i < 3; i++) {
        v[i] = j.at(i).get<float>();
        require(std::isfinite(v[i]), "Nonfinite coordinate");
    }
    return v;
}
inline size_t integer(const Json &j, size_t limit) {
    require(j.is_number_integer() && !j.is_number_float(), "Expected nonnegative integer");
    if (j.is_number_integer() && !j.is_number_unsigned())
        require(j.get<int64_t>() >= 0, "Negative integer");
    const auto n = j.get<uint64_t>();
    require(n <= limit, "Integer outside supported range");
    return size_t(n);
}
struct Part {
    float radius = 0, length = 0, offset = 0;
};
inline Part part(const Json &j) {
    Part p{j.at("radius").get<float>(), j.at("length").get<float>(), j.value("offset", 0.f)};
    require(std::isfinite(p.radius) && p.radius > 0 && std::isfinite(p.length) && p.length > 0 &&
                std::isfinite(p.offset),
            "Invalid tool part");
    return p;
}
struct Step {
    fs::path file;
    std::string stage;
    uint64_t occupied = 0;
    size_t changed = 0, bytes = 0;
    Vec tool{}, axis{0, 0, 1};
    Part cutter, shank, holder;
    std::vector<std::array<float,2>> profile;
    bool unsupportedCutter = false;
};
class History {
  public:
    fs::path root;
    std::array<uint32_t, 3> n{}, nb{};
    Vec origin{}, low{}, high{};
    float h = 0, tolerance = 0;
    uint64_t initial = 0, final = 0;
    uint32_t firstOperation = 0;
    bool liveAssets = false, liveHistory = false;
    std::vector<uint32_t> targetBlocks, fixtureBlocks;
    std::vector<uint64_t> targetPool, fixturePool;
    Json contacts=Json::array();
    size_t frame = 0, initialSlots = 0, declaredSlots = 0;
    std::vector<uint32_t> blocks, slotOwner;
    std::vector<uint64_t> pool;
    std::vector<Step> steps;
    std::vector<uint32_t> provenance; // u64 cell, u32 operation, u32 tool, little endian words
    bool hasProvenance = false, provenanceAllFrames = false;
    bool provenanceAvailableAtFrame() const { return provenanceAllFrames || frame == steps.size(); }
    std::vector<size_t> dirtyBlocks, dirtySlots;
    explicit History(const fs::path &path) {
        root = path.parent_path();
        const auto text = read(path, 64 << 20);
        auto j = Json::parse(text);
        if (j.at("format") == "menkh-quads-v1") {
            require(j.contains("voxel_history"),
                    "Legacy drill mesh animation has no voxel history. Regenerate with a current menkh drill, or use drill --grid 256 and open voxel-animation.json.");
            const auto name = j.at("voxel_history").get<std::string>();
            require(!name.empty() && name != "." && name != ".." &&
                        name.find_first_of("/\\:") == std::string::npos,
                    "Invalid voxel history filename");
            const auto legacy = std::move(j);
            j = Json::parse(read(root / fs::u8path(name), 64 << 20));
            require(j.at("voxel_mm") == legacy.at("voxel_mm") &&
                        legacy.at("frames").size() == j.at("frames").size() + 1 &&
                        legacy.at("frames").front().at("occupied") == j.at("initial_occupied") &&
                        legacy.at("frames").back().at("occupied") == j.at("final_occupied"),
                    "Drill mesh and voxel history disagree");
        }
        require(j.at("format") == "menkh-voxel-history-v1", "Unsupported history format");
        if(j.contains("live_sequence")) { liveHistory=true; firstOperation=uint32_t(integer(j.at("first_operation"),UINT32_MAX)); liveAssets=j.value("live_assets",false); require(uint64_t(firstOperation)+j.at("frames").size()<=UINT32_MAX && j.at("completed_operations")==uint64_t(firstOperation)+j.at("frames").size(),"Invalid live operation range"); }
        require(j.at("grid").size() == 3 && j.at("block_grid").size() == 3, "Invalid dimensions");
        size_t count = 1;
        uint64_t cells = 1;
        for (size_t k = 0; k < 3; k++) {
            n[k] = uint32_t(integer(j.at("grid").at(k), 4096));
            require(n[k] > 0, "Empty dimension");
            nb[k] = uint32_t(integer(j.at("block_grid").at(k), 512));
            require(nb[k] == (n[k] + 7) / 8, "Invalid block grid");
            count *= nb[k];
            cells *= n[k];
        }
        h = j.at("voxel_mm").get<float>();
        require(std::isfinite(h) && h > 0, "Invalid voxel spacing");
        if (j.contains("origin_mm"))
            origin = vec(j.at("origin_mm"));
        low = vec(j.at("stock_min"));
        high = vec(j.at("stock_max"));
        for (size_t k = 0; k < 3; k++)
            require(low[k] < high[k], "Invalid scene bounds");
        tolerance = j.value("motion_tolerance_mm", 0.f);
        require(std::isfinite(tolerance) && tolerance >= 0, "Invalid motion tolerance");
        initial = integer(j.at("initial_occupied"), size_t(cells));
        final = integer(j.at("final_occupied"), size_t(initial));
        const size_t slots = integer(j.at("pool_slots"), count);
        declaredSlots = slots;
        require(slots <= (size_t(1) << 30) / 64, "Viewer pool exceeds 1 GiB limit");
        const auto bd = read(root / "initial.blocks");
        require(bd.size() == count * 4, "Invalid block file length");
        blocks.resize(count);
        const auto pd = read(root / "initial.pool");
        require(pd.size() % 64 == 0 && pd.size() / 64 <= slots, "Invalid pool file length");
        initialSlots = pd.size() / 64;
        pool.resize(std::max(size_t(8), slots * 8));
        for (size_t i = 0; i < pd.size() / 8; i++)
            pool[i] = u64(pd.data() + i * 8);
        slotOwner.assign(slots, Empty);
        for (size_t i = 0; i < count; i++) {
            const auto d = u32(bd.data() + i * 4);
            blocks[i] = d;
            if (d < Full) {
                require(d < initialSlots && slotOwner[d] == Empty,
                        "Invalid or aliased initial slot");
                slotOwner[d] = uint32_t(i);
                validBits(i, pd.data() + size_t(d) * 64);
            }
        }
        require(j.at("frames").is_array() && j.at("frames").size() <= 100000, "Too many frames");
        uint64_t previous = initial;
        for (const auto &f : j.at("frames")) {
            Step s;
            const auto name = f.at("file").get<std::string>();
            require(!name.empty() && name != "." && name != ".." &&
                        name.find_first_of("/\\:") == std::string::npos,
                    "Invalid delta filename");
            s.file = fs::u8path(name);
            s.stage = f.at("stage").get<std::string>();
            s.occupied = integer(f.at("occupied"), size_t(previous));
            previous = s.occupied;
            s.changed = integer(f.at("changed_blocks"), count);
            s.bytes = integer(f.at("delta_bytes"), size_t(1) << 30);
            require(s.changed <= s.bytes / 12 && s.bytes <= s.changed * 140,
                    "Impossible delta record size");
            s.tool = vec(f.at("tool"));
            if (f.contains("axis"))
                s.axis = vec(f.at("axis"));
            const float len = s.axis[0] * s.axis[0] + s.axis[1] * s.axis[1] + s.axis[2] * s.axis[2];
            require(std::abs(len - 1) < 1e-4, "Invalid tool axis");
            if (f.contains("cutter") && !f.at("cutter").is_null()) {
                if (f.at("cutter").at("kind") == "flat")
                    s.cutter = part(f.at("cutter"));
                else if (f.at("cutter").at("kind") == "profile") {
                    const auto &c=f.at("cutter");s.cutter=part(c);
                    const auto &points=c.at("profile");
                    require(points.is_array() && points.size()>=2 && points.size()<=256,"Invalid wheel profile size");
                    for(const auto &p:points) {
                        const float z=p.at("z").get<float>(),r=p.at("radius").get<float>();
                        require(std::isfinite(z)&&std::isfinite(r)&&r>=0&&r<=s.cutter.radius&&(s.profile.empty()||z>s.profile.back()[0]),"Invalid or unrepresentable wheel profile");
                        s.profile.push_back({z,r});
                    }
                    require(s.profile.front()[0]==0&&s.profile.back()[0]==s.cutter.length,"Invalid wheel profile caps");
                } else
                    s.unsupportedCutter = true;
            }
            if (f.contains("shank") && !f.at("shank").is_null())
                s.shank = part(f.at("shank"));
            if (f.contains("holder") && !f.at("holder").is_null())
                s.holder = part(f.at("holder"));
            steps.push_back(s);
        }
        require(previous == final, "Final frame count mismatch");
        require(occupied() == initial, "Initial occupied count mismatch");
        loadProvenance();
        loadInspection();
    }
    void loadInspection() {
        const auto assets=liveAssets ? root.parent_path()/"assets" : root;
        auto load=[&](const char *prefix,std::vector<uint32_t> &desc,std::vector<uint64_t> &bits) {
            const auto bf=assets/(std::string(prefix)+".blocks"),pf=assets/(std::string(prefix)+".pool");
            require(fs::exists(bf)==fs::exists(pf),"Incomplete inspection buffers");
            if(!fs::exists(bf))return;
            const auto bd=read(bf),pd=read(pf);
            require(bd.size()==blocks.size()*4 && pd.size()%64==0,"Invalid inspection buffer lengths");
            desc.resize(blocks.size());bits.resize(pd.size()/8);
            for(size_t i=0;i<bits.size();++i)bits[i]=u64(pd.data()+i*8);
            for(size_t i=0;i<desc.size();++i){desc[i]=u32(bd.data()+i*4);if(desc[i]<Full){require(desc[i]<pd.size()/64,"Invalid inspection descriptor");validBits(i,pd.data()+size_t(desc[i])*64);}}
        };
        load("target",targetBlocks,targetPool);load("fixture",fixtureBlocks,fixturePool);
        require(!liveAssets || !targetBlocks.empty() || !fixtureBlocks.empty(),"Missing live inspection assets");
        if(fs::exists(root/"report.json")) {
            const auto report=Json::parse(read(root/"report.json",64<<20));
            if(report.value("format","")=="menkh-job-report-v1") {
                require(report.at("voxel_mm").get<float>()==h && vec(report.at("origin_mm"))==origin && report.at("remaining_occupied")==final && report.at("operations").size()==steps.size(),"Inspection report mismatch");
                if(liveHistory)require(report.at("first_operation")==firstOperation,"Inspection report range mismatch");
                for(size_t i=0;i<steps.size();++i){const auto &op=report.at("operations").at(i);require(op.at("id")==steps[i].stage,"Inspection operation mismatch");
                    for(const char *kind:{"shank_stock","holder_stock","shank_fixture","holder_fixture","cutter_fixture"}) {
                        const auto &contact=op.at(kind);
                        if(contact.at("occupied_centers").get<uint64_t>()>0 || contact.value("clearance","")=="unresolved_voxel_contact")
                            contacts.push_back(Json{{"operation",firstOperation+i+1},{"frame",i+1},{"id",steps[i].stage},{"kind",kind},{"stock_state_before_operation",firstOperation+i},{"contact",contact}});
                    }
                }
            }
        }
    }
    bool filled(const std::array<int,3> &p,int kind=0) const {
        for(size_t k=0;k<3;++k)if(p[k]<0 || uint32_t(p[k])>=n[k])return false;
        const auto &desc=kind==1?targetBlocks:kind==2?fixtureBlocks:blocks;
        const auto &bits=kind==1?targetPool:kind==2?fixturePool:pool;
        if(desc.empty())return false;
        const auto d=desc[(size_t(p[2]/8)*nb[1]+p[1]/8)*nb[0]+p[0]/8];
        return d==Full || (d<Full && (bits[size_t(d)*8+p[2]%8]&(uint64_t(1)<<(p[1]%8*8+p[0]%8))));
    }
    Json comparison() const {
        if(targetBlocks.empty())return nullptr;
        uint64_t excess=0,missing=0;
        for(size_t b=0;b<blocks.size();++b) {
            const auto p=coords(b);uint64_t xy=0;
            const auto ex=std::min(size_t(8),n[0]-p[0]*8),ey=std::min(size_t(8),n[1]-p[1]*8);
            for(size_t y=0;y<ey;++y)xy|=((uint64_t(1)<<ex)-1)<<(8*y);
            for(size_t z=0;z<8;++z){const uint64_t valid=p[2]*8+z<n[2]?xy:0;
                auto word=[&](uint32_t d,const std::vector<uint64_t> &bits){return d==Empty?uint64_t(0):d==Full?valid:bits[size_t(d)*8+z];};
                const auto a=word(blocks[b],pool),t=word(targetBlocks[b],targetPool);excess+=pop(a&~t);missing+=pop(t&~a);
            }
        }
        return Json{{"completed_operation",uint64_t(firstOperation)+frame},{"excess_voxels",excess},{"missing_voxels",missing},{"excess_mm3",excess*double(h)*h*h},{"missing_mm3",missing*double(h)*h*h},{"raster_approximation",true}};
    }
    void loadProvenance() {
        const auto path = root / "surface-provenance.json";
        if (!fs::exists(path)) return;
        const auto j = Json::parse(read(path, 64 << 20));
        const bool live=j.at("format")=="menkh-live-provenance-v1";
        require((live || j.at("format") == "menkh-surface-provenance-v1") && (j.at("scope") == "final_surface" || j.at("scope") == "all_frames") &&
                j.at("grid") == Json(n) && vec(j.at("origin_mm")) == origin &&
                j.at("voxel_mm").get<float>() == h && j.at("final_occupied") == final &&
                j.at("record_bytes") == 16 && j.at("initial_id") == 0,
                "Provenance does not match history");
        const auto ops = live ? Json::array() : j.at("operations");
        if(live) require(liveHistory && j.at("scope")=="all_frames" && j.at("first_operation")==firstOperation && j.at("completed_operations")==uint64_t(firstOperation)+steps.size(),"Live provenance range mismatch");
        else require(ops.is_array() && ops.size() == steps.size(), "Provenance operation count mismatch");
        for(size_t i=0;i<ops.size();++i)
            require(ops.at(i).at("id") == steps[i].stage, "Provenance operation ID mismatch");
        const size_t entries = integer(j.at("entries"), 67108864);
        require(integer(j.at("bytes"), size_t(1)<<30) == entries*16, "Invalid provenance size");
        const auto bytes = read(root / "surface-provenance.bin");
        require(bytes.size() == entries*16, "Invalid provenance buffer length");
        uint64_t previous = 0, cells = uint64_t(n[0])*n[1]*n[2];
        provenance.resize(entries*4);
        for(size_t i=0;i<entries;++i) {
            const auto *p=bytes.data()+i*16;
            const uint64_t key=u64(p); const uint32_t op=u32(p+8), tool=u32(p+12);
            require(key<cells && (!i || key>previous) && op>0 && op<=uint64_t(firstOperation)+steps.size(), "Invalid provenance entry");
            if(live) { require(tool<=integer(j.at("tool_count"),UINT32_MAX-1),"Invalid live tool ID"); } else {
            const auto &source=ops.at(op-1);
            const uint32_t expected=source.contains("tool") && !source.at("tool").is_null()
                ? uint32_t(integer(source.at("tool"), uint64_t(UINT32_MAX)-1)+1) : 0;
            require(tool==expected,"Provenance tool mismatch"); }
            for(size_t w=0;w<4;++w) provenance[i*4+w]=u32(p+w*4);
            previous=key;
        }
        provenanceAllFrames=j.at("scope")=="all_frames";
        hasProvenance=true;
    }
    void verifyExposureOracle(const fs::path &path) {
        const auto oracle=Json::parse(read(path));
        for(int pass=0;pass<3;++pass)for(size_t i=0;i<oracle.size();++i){
            const auto &f=oracle.at(pass==1?oracle.size()-1-i:i);seek(f.at("frame").get<size_t>());
            if(f.contains("excess_voxels")){const auto actual=comparison();require(actual.at("excess_voxels")==f.at("excess_voxels") && actual.at("missing_voxels")==f.at("missing_voxels"),"Target comparison oracle mismatch");}
            for(const auto &row:f.at("neighbors")) {
                const auto value=exposure(row.at(0).get<uint64_t>());
                require(value[0]==row.at(1).get<uint32_t>() && value[1]==row.at(2).get<uint32_t>(),"Exposure oracle mismatch");
            }
        }
    }
    // Query an empty neighbor cell at the current replay frame; face selection
    // remains the caller's responsibility (clip interiors are not cut faces).
    std::array<uint32_t,2> exposure(uint64_t key) const {
        if (!hasProvenance || !provenanceAvailableAtFrame() || key>=uint64_t(n[0])*n[1]*n[2]) return {};
        const size_t x=size_t(key%n[0]),y=size_t(key/n[0]%n[1]),z=size_t(key/(uint64_t(n[0])*n[1]));
        const auto d=blocks[(z/8*nb[1]+y/8)*nb[0]+x/8];
        if (d==Full || (d<Full && (pool[size_t(d)*8+z%8] & (uint64_t(1)<<(y%8*8+x%8))))) return {};
        size_t lo=0,hi=provenance.size()/4;
        while(lo<hi){size_t mid=lo+(hi-lo)/2;uint64_t value=uint64_t(provenance[mid*4])|(uint64_t(provenance[mid*4+1])<<32);if(value<key)lo=mid+1;else hi=mid;}
        if(lo<provenance.size()/4 && (uint64_t(provenance[lo*4])|(uint64_t(provenance[lo*4+1])<<32))==key && provenance[lo*4+2]<=uint64_t(firstOperation)+frame) return {provenance[lo*4+2],provenance[lo*4+3]};
        return {};
    }
    std::array<size_t, 3> coords(size_t i) const {
        return {i % nb[0], (i / nb[0]) % nb[1], i / (size_t(nb[0]) * nb[1])};
    }
    void validBits(size_t id, const uint8_t *p) const {
        auto b = coords(id);
        const size_t ex = std::min(size_t(8), size_t(n[0]) - b[0] * 8),
                     ey = std::min(size_t(8), size_t(n[1]) - b[1] * 8),
                     ez = std::min(size_t(8), size_t(n[2]) - b[2] * 8);
        uint64_t xy = 0;
        for (size_t y = 0; y < ey; y++)
            xy |= ((uint64_t(1) << ex) - 1) << (y * 8);
        for (size_t z = 0; z < 8; z++)
            require((u64(p + 8 * z) & ~(z < ez ? xy : 0)) == 0, "Bits outside grid");
    }
    uint64_t occupied() const {
        uint64_t total = 0;
        for (size_t i = 0; i < blocks.size(); i++) {
            auto d = blocks[i];
            if (d == Empty)
                continue;
            if (d == Full) {
                auto b = coords(i);
                size_t v = 1;
                for (size_t k = 0; k < 3; k++)
                    v *= std::min(size_t(8), size_t(n[k]) - b[k] * 8);
                total += v;
            } else
                for (size_t z = 0; z < 8; z++)
                    total += pop(pool[size_t(d) * 8 + z]);
        }
        return total;
    }
    void apply(size_t index, bool forward) {
        const auto &step = steps.at(index);
        const auto data = read(root / step.file);
        require(data.size() == step.bytes, "Delta length mismatch");
        struct Change {
            uint32_t id, old, next;
            size_t before, after;
        };
        std::vector<Change> changes;
        changes.reserve(step.changed);
        size_t cursor = 0;
        uint32_t previous = 0;
        bool first = true;
        while (cursor < data.size()) {
            require(data.size() - cursor >= 12, "Truncated delta");
            Change c{u32(data.data() + cursor), u32(data.data() + cursor + 4),
                     u32(data.data() + cursor + 8), 0, 0};
            cursor += 12;
            require(c.id < blocks.size() && (first || c.id > previous),
                    "Invalid delta block order");
            previous = c.id;
            first = false;
            c.before = cursor;
            if (c.old < Full) {
                require(size_t(c.old) < declaredSlots && data.size() - cursor >= 64,
                        "Invalid old pool slot");
                validBits(c.id, data.data() + cursor);
                cursor += 64;
            }
            c.after = cursor;
            if (c.next < Full) {
                require(size_t(c.next) < declaredSlots && data.size() - cursor >= 64,
                        "Invalid new pool slot");
                validBits(c.id, data.data() + cursor);
                cursor += 64;
            }
            const auto expected = forward ? c.old : c.next;
            require(blocks[c.id] == expected, "History state mismatch");
            const auto target = forward ? c.next : c.old;
            if (target < Full)
                require(slotOwner[target] == Empty || slotOwner[target] == c.id,
                        "Aliased target slot");
            if (expected < Full)
                for (size_t z = 0; z < 8; z++)
                    require(pool[size_t(expected) * 8 + z] ==
                                u64(data.data() + (forward ? c.before : c.after) + 8 * z),
                            "History bits mismatch");
            changes.push_back(c);
        }
        require(changes.size() == step.changed, "Delta record count mismatch");
        std::vector<uint32_t> targets;
        targets.reserve(changes.size());
        for (const auto &c : changes) {
            const auto d = forward ? c.next : c.old;
            if (d < Full)
                targets.push_back(d);
        }
        std::sort(targets.begin(), targets.end());
        require(std::adjacent_find(targets.begin(), targets.end()) == targets.end(),
                "Aliased delta targets");
        // All validation and reservations precede mutation. Existing producer never aliases slots.
        dirtyBlocks.reserve(dirtyBlocks.size() + changes.size());
        dirtySlots.reserve(dirtySlots.size() + changes.size());
        for (const auto &c : changes) {
            auto d = forward ? c.next : c.old;
            const auto old = blocks[c.id];
            if (old < Full)
                slotOwner[old] = Empty;
            if (d < Full) {
                require(slotOwner[d] == Empty, "Aliased delta target");
                slotOwner[d] = c.id;
            }
            blocks[c.id] = d;
            dirtyBlocks.push_back(c.id);
            if (d < Full) {
                for (size_t z = 0; z < 8; z++)
                    pool[size_t(d) * 8 + z] =
                        u64(data.data() + (forward ? c.after : c.before) + 8 * z);
                dirtySlots.push_back(d);
            }
        }
    }
    void seek(size_t target) {
        require(target <= steps.size(), "Frame out of range");
        while (frame < target) {
            apply(frame, true);
            frame++;
        }
        while (frame > target) {
            apply(frame - 1, false);
            frame--;
        }
    }
    void verify() {
        const auto bd = blocks;
        const std::vector<uint64_t> pd(pool.begin(), pool.begin() + initialSlots * 8);
        seek(steps.size());
        require(occupied() == final, "Final occupancy mismatch");
        const auto finalBlocks = blocks;
        const auto finalPool = pool;
        seek(0);
        require(blocks == bd && std::equal(pd.begin(), pd.end(), pool.begin()),
                "Undo differs from initial state");
        seek(steps.size());
        require(blocks == finalBlocks && pool == finalPool, "Replay differs");
        seek(0);
    }
};
} // namespace menkh
