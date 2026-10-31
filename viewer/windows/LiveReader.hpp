#pragma once
#include "History.hpp"
#include <windows.h>
#include <memory>
namespace menkh {
// Locks the same byte range as Zig's Windows file locks. The handle, not the
// currently open delta file, leases the entire lazy history window.
class LiveLease {
    HANDLE handle = INVALID_HANDLE_VALUE;
    OVERLAPPED overlapped{};
    bool locked=false;
public:
    explicit LiveLease(const fs::path &path) {
        handle=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        require(handle!=INVALID_HANDLE_VALUE,"Cannot open live lease");
        locked=LockFileEx(handle,LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&overlapped)!=FALSE;
        if(!locked && GetLastError()!=ERROR_LOCK_VIOLATION){CloseHandle(handle);handle=INVALID_HANDLE_VALUE;throw std::runtime_error("Cannot acquire live lease");}
    }
    ~LiveLease(){if(locked)UnlockFileEx(handle,0,1,0,&overlapped);if(handle!=INVALID_HANDLE_VALUE)CloseHandle(handle);}
    LiveLease(const LiveLease&)=delete;
    LiveLease& operator=(const LiveLease&)=delete;
    explicit operator bool()const{return locked;}
};
struct LiveWindow {
    std::unique_ptr<LiveLease> lease;
    fs::path manifest;
    Json pointer, metadata;
};
inline std::optional<LiveWindow> nextLiveWindow(const fs::path &output, uint64_t sequence) {
    const auto root=output/"live";
    if(!fs::is_regular_file(root/"latest.json"))return std::nullopt;
    const auto pointer=Json::parse(read(root/"latest.json",65536));
    require(pointer.at("version")==1,"Unsupported live pointer");
    const auto next=pointer.at("sequence").get<uint64_t>();
    if(next<=sequence)return std::nullopt;
    const int slot=pointer.at("slot").get<int>();require(slot>=0 && slot<3,"Invalid live slot");
    auto lease=std::make_unique<LiveLease>(root/("slot-"+std::to_string(slot)+".lock"));
    if(!*lease)return std::nullopt;
    const auto file=root/("slot-"+std::to_string(slot))/"voxel-animation.json";
    const auto metadata=Json::parse(read(file,64<<20));
    if(metadata.at("live_sequence")!=next)return std::nullopt;
    require(metadata.at("first_operation")==pointer.at("first_operation") && metadata.at("completed_operations")==pointer.at("completed_operations"),"Live operation range mismatch");
    const auto first=metadata.at("first_operation").get<uint64_t>(),end=metadata.at("completed_operations").get<uint64_t>();
    require(first<=end && end-first==metadata.at("frames").size() && end<=metadata.at("total_operations").get<uint64_t>(),"Invalid live operation range");
    return LiveWindow{std::move(lease),file,pointer,metadata};
}
} // namespace menkh
