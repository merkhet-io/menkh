#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "History.hpp"
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <d3dcompiler.h>
#include <dxgi1_6.h>
#include <iostream>
#include <sstream>
#include <mutex>
#include <windows.h>
#include <wrl/client.h>
namespace menkh {
using Microsoft::WRL::ComPtr;
inline void hr(HRESULT code, const char *where) {
    if (FAILED(code)) {
        std::ostringstream out;
        out << where << " (HRESULT 0x" << std::hex << uint32_t(code) << ")";
        throw std::runtime_error(out.str());
    }
}
struct F4 {
    float x = 0, y = 0, z = 0, w = 0;
};
struct U4 {
    uint32_t x = 0, y = 0, z = 0, w = 0;
};
struct Uniforms {
    F4 eye, forward, right, up, low, high, settings;
    U4 dimensions, blockDimensions, flags;
    F4 shank, shankAxis, holder, holderAxis, cutter, cutterAxis;
    std::array<F4,256> wheelProfile;
};
static_assert(sizeof(Uniforms) == 4352, "HLSL constant buffer layout");
inline Vec add(Vec a, Vec b) { return {a[0] + b[0], a[1] + b[1], a[2] + b[2]}; }
inline Vec mul(Vec a, float s) { return {a[0] * s, a[1] * s, a[2] * s}; }
inline Vec sub(Vec a, Vec b) { return add(a, mul(b, -1)); }
inline Vec cross(Vec a, Vec b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline float length(Vec a) { return std::sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); }
inline Vec unit(Vec a) { return mul(a, 1 / length(a)); }
inline F4 four(Vec v, float w = 0) { return {v[0], v[1], v[2], w}; }
struct Camera {
    Vec target{};
    float distance = 1, yaw = -.8f, elevation = .5f, section = 1;
    uint32_t colorMode = 0; // 0 material, 1 exposing operation, 2 exposing tool
    bool dark = false, tool = true, antialias = true, smoothLighting = false;
    bool compare=false,fixtures=true,stock=true,targetVisible=false;
    uint32_t sectionAxis=2;
    void reset(const History &h) {
        target = mul(add(h.low, h.high), .5f);
        distance = std::max(1.f, length(sub(h.high, h.low)) * 1.5f);
        yaw = -.8f;
        elevation = .5f;
        section = 1;
    }
    Json pick(const History &h,float x,float y,uint32_t width,uint32_t height) const {
        const auto u=uniforms(h,width,height);
        const Vec eye{u.eye.x,u.eye.y,u.eye.z},f{u.forward.x,u.forward.y,u.forward.z},r{u.right.x,u.right.y,u.right.z},up{u.up.x,u.up.y,u.up.z};
        const auto ray=unit(add(f,mul(add(mul(r,(2*x-1)*float(width)/height),mul(up,1-2*y)),u.settings.w)));
        Vec inverse{},slabNear{},slabFar{};const Vec low{u.low.x,u.low.y,u.low.z},high{u.high.x,u.high.y,u.high.z};
        for(size_t i=0;i<3;++i){inverse[i]=1/(std::abs(ray[i])<1e-15f?1e-15f:ray[i]);const float a=(low[i]-eye[i])*inverse[i],b=(high[i]-eye[i])*inverse[i];slabNear[i]=std::min(a,b);slabFar[i]=std::max(a,b);}
        size_t axis=size_t(std::max_element(slabNear.begin(),slabNear.end())-slabNear.begin());
        float t=std::max(0.f,slabNear[axis]),end=*std::min_element(slabFar.begin(),slabFar.end());
        for(uint64_t step=0;t<=end && step<uint64_t(h.n[0])+h.n[1]+h.n[2]+8;++step){
            const auto pos=add(eye,mul(ray,t+.001f));std::array<int,3> cell{int(std::floor(pos[0])),int(std::floor(pos[1])),int(std::floor(pos[2]))};
            for(size_t i=0;i<3;++i)if(cell[i]<0 || uint32_t(cell[i])>=h.n[i])return nullptr;
            if(h.filled(cell)){
                const auto surface=add(eye,mul(ray,t));auto neighbor=cell;neighbor[axis]+=ray[axis]>0?-1:1;
                std::array<uint32_t,2> exposure{};
                if(std::abs(surface[axis]-std::round(surface[axis]))<.01f && neighbor[0]>=0 && neighbor[1]>=0 && neighbor[2]>=0 && uint32_t(neighbor[0])<h.n[0] && uint32_t(neighbor[1])<h.n[1] && uint32_t(neighbor[2])<h.n[2])
                    exposure=h.exposure((uint64_t(neighbor[2])*h.n[1]+neighbor[1])*h.n[0]+neighbor[0]);
                return Json{{"position_mm",add(h.origin,mul(surface,h.h))},{"cell",cell},{"exposure_neighbor",neighbor},{"occupied",true},{"in_target",h.targetBlocks.empty()?Json(nullptr):Json(h.filled(cell,1))},{"operation",exposure[0]},{"tool_id",exposure[1]},{"completed_operation",uint64_t(h.firstOperation)+h.frame},{"surface","material; tool/fixture overlays ignored"}};
            }
            Vec next{};for(size_t i=0;i<3;++i)next[i]=(float(cell[i]+(ray[i]>0?1:0))-eye[i])*inverse[i];
            axis=size_t(std::min_element(next.begin(),next.end())-next.begin());t=std::max(next[axis],t+.001f);
        }
        return nullptr;
    }
    Uniforms uniforms(const History &h, uint32_t width, uint32_t height) const {
        const Vec offset = mul(Vec{std::cos(elevation) * std::cos(yaw),
                                   std::cos(elevation) * std::sin(yaw), std::sin(elevation)},
                               distance);
        const Vec eye = add(target, offset), f = unit(mul(offset, -1)),
                  r = unit(cross(f, Vec{0, 0, 1})), u = cross(r, f);
        Uniforms v{};
        v.eye = four(mul(sub(eye, h.origin), 1 / h.h));
        v.forward = four(f);
        v.right = four(r);
        v.up = four(u);
        Vec low{}, high{};
        for (size_t i = 0; i < 3; i++) {
            low[i] = std::max(0.f, (h.low[i] - h.origin[i]) / h.h - 1);
            high[i] = std::min(float(h.n[i]), (h.high[i] - h.origin[i]) / h.h + 1);
        }
        high[sectionAxis] = std::min(high[sectionAxis], float(h.n[sectionAxis]) * section);
        v.low = four(low);
        v.high = four(high);
        v.settings = {h.h, float(width), float(height), .41421356f};
        v.dimensions = {h.n[0], h.n[1], h.n[2], uint32_t(h.firstOperation+h.frame)};
        v.blockDimensions = {h.nb[0], h.nb[1], h.nb[2], uint32_t(compare && !h.targetBlocks.empty()) | (uint32_t(fixtures && !h.fixtureBlocks.empty())<<1) | (uint32_t(!stock)<<2) | (uint32_t(targetVisible && !h.targetBlocks.empty())<<3)};
        v.flags = {uint32_t(dark), (uint32_t(antialias) | (uint32_t(smoothLighting)<<1)), h.provenanceAvailableAtFrame() && !compare ? colorMode : 0, uint32_t(h.provenance.size()/4)};
        if (tool && h.frame) {
            const auto &s = h.steps[h.frame - 1];
            auto set = [&](Part p, F4 &radial, F4 &axial) {
                radial = four(mul(sub(add(s.tool, mul(s.axis, p.offset)), h.origin), 1 / h.h),
                              p.radius / h.h);
                axial = four(s.axis, p.length / h.h);
            };
            set(s.cutter, v.cutter, v.cutterAxis);
            v.eye.w=float(s.profile.size());
            for(size_t i=0;i<s.profile.size();++i)v.wheelProfile[i]={s.profile[i][0]/h.h,s.profile[i][1]/h.h,0,0};
            set(s.shank, v.shank, v.shankAxis);
            set(s.holder, v.holder, v.holderAxis);
        }
        return v;
    }
};
class Renderer {
    ComPtr<IDXGIFactory4> factory;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12DescriptorHeap> heap;
    ComPtr<IDXGISwapChain3> swap;
    ComPtr<ID3D12Resource> output;
    HANDLE event = nullptr;
    uint64_t serial = 0;
    struct Buffer {
        ComPtr<ID3D12Resource> gpu, upload;
        uint8_t *mapped = nullptr;
        size_t size = 0;
    };
    Buffer blocks, pool, provenance, targetBlocks, targetPool, fixtureBlocks, fixturePool;
    uint32_t width = 0, height = 0;
    bool initial = true;
    std::wstring adapterLabel;
    static ComPtr<ID3DBlob> shaderCode(const fs::path &path) {
        // A live publication changes material, not the shader. Keep one compiled
        // shader per process instead of blocking the UI on every window load.
        // Restart the viewer after editing the shader at the same path.
        static std::mutex lock;
        static fs::path cachedPath;
        static ComPtr<ID3DBlob> cached;
        std::lock_guard<std::mutex> guard(lock);
        if (!cached || cachedPath != path) {
            ComPtr<ID3DBlob> code, error;
            const auto result = D3DCompileFromFile(
                path.c_str(), nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE, "main", "cs_5_0",
                D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &error);
            if (FAILED(result))
                throw std::runtime_error(error ? std::string(
                    static_cast<const char *>(error->GetBufferPointer()), error->GetBufferSize())
                    : "Cannot compile Voxel.hlsl beside executable");
            cachedPath = path;
            cached = std::move(code);
        }
        return cached;
    }
    ComPtr<ID3D12Resource> buffer(size_t bytes, D3D12_HEAP_TYPE type, D3D12_RESOURCE_STATES state) {
        D3D12_HEAP_PROPERTIES hp{};
        hp.Type = type;
        D3D12_RESOURCE_DESC d{};
        d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        d.Width = std::max(size_t(64), bytes);
        d.Height = 1;
        d.DepthOrArraySize = 1;
        d.MipLevels = 1;
        d.SampleDesc.Count = 1;
        d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> resource;
        hr(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d, state, nullptr,
                                           IID_PPV_ARGS(&resource)),
           "Create buffer");
        return resource;
    }
    Buffer dataBuffer(size_t bytes) {
        Buffer b;
        b.size = bytes;
        b.gpu =
            buffer(bytes, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COMMON);
        b.upload = buffer(bytes, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
        D3D12_RANGE range{0, 0};
        hr(b.upload->Map(0, &range, reinterpret_cast<void **>(&b.mapped)), "Map staging buffer");
        return b;
    }
    void transition(ID3D12Resource *r, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
        D3D12_RESOURCE_BARRIER b{};
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition = {r, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, before, after};
        commands->ResourceBarrier(1, &b);
    }
    void begin() {
        hr(allocator->Reset(), "Reset allocator");
        hr(commands->Reset(allocator.Get(), pipeline.Get()), "Reset commands");
    }
    void diagnostics() {
        ComPtr<ID3D12InfoQueue> messages;
        if (SUCCEEDED(device.As(&messages))) {
            for (UINT64 i = 0; i < messages->GetNumStoredMessagesAllowedByRetrievalFilter(); i++) {
                SIZE_T size = 0;
                messages->GetMessage(i, nullptr, &size);
                std::vector<uint8_t> storage(size);
                auto *m = reinterpret_cast<D3D12_MESSAGE *>(storage.data());
                if (SUCCEEDED(messages->GetMessage(i, m, &size)))
                    std::cerr << "D3D12: " << m->pDescription << '\n';
            }
            messages->ClearStoredMessages();
        }
    }
    void waitForQueue() {
        hr(queue->Signal(fence.Get(), ++serial), "Signal fence");
        if (fence->GetCompletedValue() < serial) {
            hr(fence->SetEventOnCompletion(serial, event), "Set fence event");
            require(WaitForSingleObject(event, 60000) == WAIT_OBJECT_0, "GPU timed out");
        }
        diagnostics();
        hr(device->GetDeviceRemovedReason(), "D3D12 device status");
    }
    void submit() {
        hr(commands->Close(), "Close commands");
        ID3D12CommandList *lists[] = {commands.Get()};
        queue->ExecuteCommandLists(1, lists);
        waitForQueue();
    }
    void update(Buffer &b, const void *source, std::vector<size_t> &dirty, size_t stride) {
        if (!initial && dirty.empty())
            return;
        // Buffers start in COMMON and decay back to COMMON after each completed
        // ExecuteCommandLists. submit() fences every batch before the next update.
        transition(b.gpu.Get(), D3D12_RESOURCE_STATE_COMMON,
                   D3D12_RESOURCE_STATE_COPY_DEST);
        if (initial) {
            std::memcpy(b.mapped, source, b.size);
            commands->CopyBufferRegion(b.gpu.Get(), 0, b.upload.Get(), 0, b.size);
        } else {
            std::sort(dirty.begin(), dirty.end());
            dirty.erase(std::unique(dirty.begin(), dirty.end()), dirty.end());
            for (size_t i = 0; i < dirty.size();) {
                size_t end = i + 1;
                while (end < dirty.size() && dirty[end] == dirty[end - 1] + 1)
                    end++;
                const size_t offset = dirty[i] * stride, bytes = (end - i) * stride;
                require(offset <= b.size && bytes <= b.size - offset, "Dirty range outside buffer");
                std::memcpy(b.mapped + offset, static_cast<const uint8_t *>(source) + offset,
                            bytes);
                commands->CopyBufferRegion(b.gpu.Get(), offset, b.upload.Get(), offset, bytes);
                i = end;
            }
        }
        dirty.clear();
        transition(b.gpu.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }

  public:
    Renderer(const History &history, const fs::path &shader, bool warp, bool debug) {
        if (debug) {
            static std::once_flag enabled;
            std::call_once(enabled, [] {
                ComPtr<ID3D12Debug> layer;
                hr(D3D12GetDebugInterface(IID_PPV_ARGS(&layer)), "D3D12 debug layer unavailable");
                layer->EnableDebugLayer();
            });
        }
        hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        if (warp) {
            hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "Find WARP adapter");
            hr(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)),
               "Create WARP device");
        } else {
            for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; i++) {
                DXGI_ADAPTER_DESC1 d{};
                adapter->GetDesc1(&d);
                if (!(d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
                    SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                                                IID_PPV_ARGS(&device))))
                    break;
                adapter.Reset();
            }
            require(device != nullptr,
                    "No D3D12 hardware device. Use --warp for software rendering.");
        }
        DXGI_ADAPTER_DESC1 info{};
        hr(adapter->GetDesc1(&info), "Get adapter description");
        adapterLabel = info.Description;
        D3D12_COMMAND_QUEUE_DESC q{};
        q.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        hr(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)), "Create queue");
        hr(device->CreateCommandAllocator(q.Type, IID_PPV_ARGS(&allocator)), "Create allocator");
        hr(device->CreateCommandList(0, q.Type, allocator.Get(), nullptr, IID_PPV_ARGS(&commands)),
           "Create commands");
        hr(commands->Close(), "Close initial commands");
        hr(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "Create fence");
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        require(event != nullptr, "Create fence event failed");
        D3D12_DESCRIPTOR_RANGE range{};
        range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
        range.NumDescriptors = 1;
        D3D12_DESCRIPTOR_RANGE srvs{};
        srvs.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        srvs.NumDescriptors = 7;
        srvs.OffsetInDescriptorsFromTableStart = 1;
        D3D12_ROOT_PARAMETER params[3]{};
        params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        params[0].Descriptor = {0, 0};
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[1].DescriptorTable = {1, &srvs};
        params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[2].DescriptorTable = {1, &range};
        D3D12_ROOT_SIGNATURE_DESC rd{};
        rd.NumParameters = 3;
        rd.pParameters = params;
        ComPtr<ID3DBlob> serialized, error;
        hr(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &serialized, &error),
           "Serialize root signature");
        hr(device->CreateRootSignature(0, serialized->GetBufferPointer(),
                                       serialized->GetBufferSize(), IID_PPV_ARGS(&root)),
           "Create root signature");
        const auto code = shaderCode(shader);
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd{};
        pd.pRootSignature = root.Get();
        pd.CS = {code->GetBufferPointer(), code->GetBufferSize()};
        hr(device->CreateComputePipelineState(&pd, IID_PPV_ARGS(&pipeline)),
           "Create compute pipeline");
        D3D12_DESCRIPTOR_HEAP_DESC hd{};
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        hd.NumDescriptors = 8;
        hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        hr(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap)), "Create descriptor heap");
        blocks = dataBuffer(history.blocks.size() * 4);
        pool = dataBuffer(history.pool.size() * 8);
        provenance = dataBuffer(std::max(size_t(4), history.provenance.size()) * 4);
        targetBlocks=dataBuffer(std::max(size_t(4),history.targetBlocks.size()*4));
        targetPool=dataBuffer(std::max(size_t(8),history.targetPool.size()*8));
        fixtureBlocks=dataBuffer(std::max(size_t(4),history.fixtureBlocks.size()*4));
        fixturePool=dataBuffer(std::max(size_t(8),history.fixturePool.size()*8));
        auto handle = heap->GetCPUDescriptorHandleForHeapStart();
        const auto increment =
            device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        for (const auto *b : {&blocks, &pool, &provenance, &targetBlocks, &targetPool, &fixtureBlocks, &fixturePool}) {
            handle.ptr += increment;
            D3D12_SHADER_RESOURCE_VIEW_DESC srv{};
            srv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
            srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            srv.Buffer.NumElements = UINT(b->size / 4);
            srv.Buffer.StructureByteStride = 4;
            device->CreateShaderResourceView(b->gpu.Get(), &srv, handle);
        }
        constants = buffer(sizeof(Uniforms), D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
        D3D12_RANGE noRead{0, 0};
        hr(constants->Map(0, &noRead, reinterpret_cast<void **>(&constantData)), "Map constants");
    }
    ~Renderer() {
        std::cerr << "D3D12 shutdown: swapchain\n";
        // DXGI may still own presentation work after the command fence completes.
        // Release the swapchain while its HWND and device/queue are still alive.
        swap.Reset();
        std::cerr << "D3D12 shutdown: event\n";
        if (event)
            CloseHandle(event);
        std::cerr << "D3D12 shutdown: resources\n";
        constants.Reset();
        blocks.upload.Reset(); blocks.gpu.Reset();
        pool.upload.Reset(); pool.gpu.Reset();
        provenance.upload.Reset(); provenance.gpu.Reset();
        targetBlocks.upload.Reset();targetBlocks.gpu.Reset();targetPool.upload.Reset();targetPool.gpu.Reset();
        fixtureBlocks.upload.Reset();fixtureBlocks.gpu.Reset();fixturePool.upload.Reset();fixturePool.gpu.Reset();
        output.Reset(); heap.Reset(); pipeline.Reset(); root.Reset();
        commands.Reset(); allocator.Reset(); fence.Reset();
        std::cerr << "D3D12 shutdown: queue\n";
        queue.Reset();
        std::cerr << "D3D12 shutdown: device\n";
        device.Reset(); factory.Reset();
        std::cerr << "D3D12 shutdown: complete\n";
    }
    ComPtr<ID3D12Resource> constants;
    uint8_t *constantData = nullptr;
    const std::wstring &adapterName() const { return adapterLabel; }
    void attach(HWND window) {
        DXGI_SWAP_CHAIN_DESC1 d{};
        d.Width = 1;
        d.Height = 1;
        d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        d.SampleDesc.Count = 1;
        d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        d.BufferCount = 2;
        d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        ComPtr<IDXGISwapChain1> s;
        hr(factory->CreateSwapChainForHwnd(queue.Get(), window, &d, nullptr, nullptr, &s),
           "Create swap chain");
        hr(s.As(&swap), "Query swap chain");
        hr(factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER), "Set window association");
    }
    void resize(uint32_t w, uint32_t h) {
        if (w == width && h == height)
            return;
        require(w > 0 && h > 0 && w <= 8192 && h <= 8192, "Invalid render dimensions");
        output.Reset();
        if (swap)
            hr(swap->ResizeBuffers(2, w, h, DXGI_FORMAT_R8G8B8A8_UNORM, 0), "Resize swap chain");
        width = w;
        height = h;
        D3D12_HEAP_PROPERTIES hp{};
        hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC d{};
        d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        d.Width = w;
        d.Height = h;
        d.DepthOrArraySize = 1;
        d.MipLevels = 1;
        d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        d.SampleDesc.Count = 1;
        d.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        hr(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d,
                                           D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr,
                                           IID_PPV_ARGS(&output)),
           "Create render image");
        D3D12_UNORDERED_ACCESS_VIEW_DESC uav{};
        uav.Format = d.Format;
        uav.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        device->CreateUnorderedAccessView(output.Get(), nullptr, &uav,
                                          heap->GetCPUDescriptorHandleForHeapStart());
    }
    void materials(History &h) {
        update(blocks, h.blocks.data(), h.dirtyBlocks, 4);
        update(pool, h.pool.data(), h.dirtySlots, 64);
        if (initial) {
            const uint32_t zero[4]{};
            std::vector<size_t> dirty;
            update(provenance, h.provenance.empty() ? zero : h.provenance.data(), dirty, 4);
            update(targetBlocks,h.targetBlocks.empty()?static_cast<const void*>(zero):h.targetBlocks.data(),dirty,4);
            update(targetPool,h.targetPool.empty()?static_cast<const void*>(zero):h.targetPool.data(),dirty,8);
            update(fixtureBlocks,h.fixtureBlocks.empty()?static_cast<const void*>(zero):h.fixtureBlocks.data(),dirty,4);
            update(fixturePool,h.fixturePool.empty()?static_cast<const void*>(zero):h.fixturePool.data(),dirty,8);
        }
        initial = false;
    }
    // Complete the CPU copy and GPU transfer before timing the first render.
    void uploadMaterial(History &h) { begin(); materials(h); submit(); }
    Json materialMemory() const {
        auto allocation=[&](ID3D12Resource *resource)->uint64_t {if(!resource)return 0;const auto desc=resource->GetDesc();return device->GetResourceAllocationInfo(0,1,&desc).SizeInBytes;};
        return Json{{"gpu_committed_material_bytes",allocation(blocks.gpu.Get())+allocation(pool.gpu.Get())+allocation(provenance.gpu.Get())},
                    {"upload_committed_material_bytes",allocation(blocks.upload.Get())+allocation(pool.upload.Get())+allocation(provenance.upload.Get())},
                    {"gpu_committed_asset_bytes",allocation(targetBlocks.gpu.Get())+allocation(targetPool.gpu.Get())+allocation(fixtureBlocks.gpu.Get())+allocation(fixturePool.gpu.Get())},
                    {"upload_committed_asset_bytes",allocation(targetBlocks.upload.Get())+allocation(targetPool.upload.Get())+allocation(fixtureBlocks.upload.Get())+allocation(fixturePool.upload.Get())},
                    {"output_texture_committed_bytes",allocation(output.Get())},{"constants_committed_bytes",allocation(constants.Get())}};
    }
    void render(History &h, const Camera &camera) {
        // Keep the acquired swapchain resource alive until command execution completes.
        ComPtr<ID3D12Resource> back;
        const auto u = camera.uniforms(h, width, height);
        std::memcpy(constantData, &u, sizeof(u));
        begin();
        materials(h);
        commands->SetComputeRootSignature(root.Get());
        ID3D12DescriptorHeap *heaps[] = {heap.Get()};
        commands->SetDescriptorHeaps(1, heaps);
        commands->SetComputeRootConstantBufferView(0, constants->GetGPUVirtualAddress());
        commands->SetComputeRootDescriptorTable(1, heap->GetGPUDescriptorHandleForHeapStart());
        commands->SetComputeRootDescriptorTable(2, heap->GetGPUDescriptorHandleForHeapStart());
        commands->Dispatch((width + 7) / 8, (height + 7) / 8, 1);
        if (swap) {
            hr(swap->GetBuffer(swap->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&back)),
               "Get swap image");
            transition(output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                       D3D12_RESOURCE_STATE_COPY_SOURCE);
            transition(back.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST);
            commands->CopyResource(back.Get(), output.Get());
            transition(back.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT);
            transition(output.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                       D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        } else {
            D3D12_RESOURCE_BARRIER barrier{};
            barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
            barrier.UAV.pResource = output.Get();
            commands->ResourceBarrier(1, &barrier);
        }
        submit();
        if (swap) {
            hr(swap->Present(1, 0), "Present");
            waitForQueue();
        }
    }
    void snapshot(const fs::path &path) {
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout{};
        UINT rows = 0;
        UINT64 rowBytes = 0, total = 0;
        const auto desc = output->GetDesc();
        device->GetCopyableFootprints(&desc, 0, 1, 0, &layout, &rows, &rowBytes, &total);
        auto dest = buffer(size_t(total), D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
        begin();
        transition(output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION from{};
        from.pResource = output.Get();
        from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION to{};
        to.pResource = dest.Get();
        to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        to.PlacedFootprint = layout;
        commands->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
        transition(output.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                   D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        submit();
        uint8_t *pixels = nullptr;
        D3D12_RANGE readRange{0, size_t(total)};
        const auto mapped = dest->Map(0, &readRange, reinterpret_cast<void **>(&pixels));
        if (FAILED(mapped)) {
            diagnostics();
            hr(device->GetDeviceRemovedReason(), "Device removed during readback");
        }
        hr(mapped, "Map image readback");
        std::ofstream f(path, std::ios::binary);
        f << "P6\n" << width << ' ' << height << "\n255\n";
        for (uint32_t y = 0; y < height; y++)
            for (uint32_t x = 0; x < width; x++)
                f.write(reinterpret_cast<const char *>(
                            pixels + layout.Offset + size_t(y) * layout.Footprint.RowPitch + x * 4),
                        3);
        dest->Unmap(0, nullptr);
        require(bool(f), "Cannot save snapshot");
    }
};
} // namespace menkh
