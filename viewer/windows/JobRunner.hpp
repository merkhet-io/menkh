#pragma once
#include <process.h>
#include "History.hpp"
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <chrono>
#include <optional>
#include <iostream>
#include <atomic>
#include <thread>
#include <functional>
#include "../../include/menkh.h"
#pragma comment(lib, "comdlg32.lib")
namespace menkh {
struct WinHandle {
    HANDLE value = nullptr;
    ~WinHandle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    WinHandle() = default;
    WinHandle(const WinHandle &) = delete;
    WinHandle &operator=(const WinHandle &) = delete;
};
inline std::wstring wide(const std::string &s) {
    const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()), nullptr, 0);
    if (!n) return L"";
    std::wstring r(size_t(n), L' ');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()), r.data(), n);
    return r;
}
// Windows CRT argument quoting; CreateProcess receives an explicit executable,
// never cmd.exe. Backslashes immediately before quotes/end need doubling.
inline std::wstring quote(const std::wstring &s) {
    std::wstring r = L"\""; size_t slash = 0;
    for (wchar_t c : s) {
        if (c == L'\\') { ++slash; continue; }
        r.append(slash * (c == L'"' ? 2 : 1), L'\\'); slash = 0;
        if (c == L'"') r += L'\\';
        r += c;
    }
    r.append(slash * 2, L'\\'); r += L'"'; return r;
}
inline fs::path viewerExecutable() {
    wchar_t path[32768]; const DWORD n = GetModuleFileNameW(nullptr, path, 32768);
    require(n && n < 32768, "Cannot locate viewer executable"); return fs::path(path);
}
inline fs::path chooseInput() {
    wchar_t file[32768]{}; OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog); dialog.lpstrFile = file; dialog.nMaxFile = 32768;
    dialog.lpstrTitle = L"Open a Menkh job or recorded history";
    dialog.lpstrFilter = L"JSON jobs and histories\0*.json\0All files\0*.*\0\0";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&dialog)) { require(CommDlgExtendedError() == 0, "File dialog failed"); return {}; }
    return fs::path(file);
}
inline fs::path findEngine(fs::path requested) {
    if (!requested.empty()) { requested = fs::absolute(requested); require(fs::is_regular_file(requested), "Selected engine executable does not exist"); return requested; }
    auto directory = viewerExecutable().parent_path();
    if (fs::is_regular_file(directory / "menkh.exe")) return directory / "menkh.exe";
    for (int i = 0; i < 5 && !directory.empty(); ++i, directory = directory.parent_path()) {
        const auto candidate = directory / "zig-out" / "bin" / "menkh.exe";
        if (fs::is_regular_file(candidate)) return candidate;
    }
    throw std::runtime_error("Simulation engine not found. Place menkh.exe beside the viewer, or supply --engine PATH.");
}
inline std::string tail(const fs::path &path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return {};
    const auto end = file.tellg(); if (end <= 0) return {};
    const auto size = std::min<uint64_t>(uint64_t(end), 65536);
    file.seekg(std::streamoff(uint64_t(end) - size));
    std::string s(size_t(size), '\0'); file.read(s.data(), std::streamsize(size)); s.resize(size_t(file.gcount())); return s;
}
inline Json lastProgress(const fs::path &path) {
    const auto text = tail(path); const auto end = text.rfind('\n');
    if (end == std::string::npos || end == 0) return {};
    const auto previous = text.rfind('\n', end - 1); const auto begin = previous == std::string::npos ? 0 : previous + 1;
    try { return Json::parse(text.substr(begin, end - begin)); } catch (...) { return {}; }
}
// Published control files are atomically replaced. Share DELETE so an open
// reader does not block the producer; tolerate the brief rename-open race.
inline std::optional<Json> readPublishedJson(const fs::path &path) {
    for(int attempt=0;attempt<20;++attempt) {
        WinHandle file;
        file.value=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(file.value==INVALID_HANDLE_VALUE) {
            const auto error=GetLastError();
            if(error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND)return std::nullopt;
            if(error==ERROR_ACCESS_DENIED || error==ERROR_SHARING_VIOLATION){Sleep(1);continue;}
            throw std::runtime_error("Cannot open live publication metadata");
        }
        LARGE_INTEGER size{};require(GetFileSizeEx(file.value,&size)!=FALSE && size.QuadPart>=0 && size.QuadPart<=65536,"Invalid live metadata size");
        std::string data(size_t(size.QuadPart),'\0');DWORD count=0;
        require(ReadFile(file.value,data.data(),DWORD(data.size()),&count,nullptr)!=FALSE && count==data.size(),"Cannot read live metadata");
        return Json::parse(data);
    }
    throw std::runtime_error("Live metadata remained inaccessible during replacement");
}
struct RunWindow {
    HWND window = nullptr, status = nullptr, progress = nullptr, cancel = nullptr;
    HANDLE group = nullptr; bool cancelled = false;
    fs::path liveOutput;
    HWND follow = nullptr, pause = nullptr;
    bool paused = false;
    bool following() const { return !follow || SendMessageW(follow, BM_GETCHECK, 0, 0) == BST_CHECKED; }
    void controlFile(const char *name, bool present) {
        if (liveOutput.empty() || !fs::is_directory(liveOutput / "live")) return;
        const auto path=liveOutput / "live" / name;
        if (present) { std::ofstream file(path); require(bool(file), "Cannot write live control"); }
        else { std::error_code error; fs::remove(path,error); require(!error,"Cannot remove live control"); }
    }
    void liveControls() {
        if (liveOutput.empty()) return;
        if(cancelled)controlFile("cancel", true);
        if (!cancelled) if(const auto state=readPublishedJson(liveOutput/"live/status.json")) {
            if (state->value("state", "") == "paused") {
                SetWindowTextW(status,(L"Paused after operation "+std::to_wstring(state->at("completed_operations").get<uint64_t>())+L". Retained history is safe to inspect.").c_str());
            }
        }
        if (pause) EnableWindow(pause, !cancelled && fs::is_directory(liveOutput/"live"));
    }
    ~RunWindow() { if (window) DestroyWindow(window); }
    void stop() {
        cancelled = true;
        if (group && liveOutput.empty()) TerminateJobObject(group, 2);
        if (!liveOutput.empty()) {try {controlFile("cancel", true);} catch (...) {if(group)TerminateJobObject(group,2);}}
        if (cancel) EnableWindow(cancel, FALSE);
        if (status) SetWindowTextW(status, group ? L"Cancelling calculation…" : L"Cancelling after the current operation…");
    }
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM w, LPARAM l) {
        auto *s = reinterpret_cast<RunWindow *>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) { s = static_cast<RunWindow *>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(s)); }
        if (s && message == WM_COMMAND && LOWORD(w) == 2) {
            try { s->controlFile("pause", !s->paused); s->paused=!s->paused;SetWindowTextW(s->pause,s->paused?L"Resume calculation":L"Pause calculation"); }
            catch(const std::exception &e){SetWindowTextW(s->status,wide(e.what()).c_str());}
            return 0;
        }
        if (s && (message == WM_CLOSE || (message == WM_COMMAND && LOWORD(w) == 1))) { s->stop(); return 0; }
        return DefWindowProcW(window, message, w, l);
    }
    void create() {
        INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_PROGRESS_CLASS}; require(InitCommonControlsEx(&controls) != FALSE, "Progress controls unavailable");
        WNDCLASSW wc{}; wc.lpfnWndProc = procedure; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"MenkhCalculation"; wc.hCursor = LoadCursorW(nullptr, IDC_ARROW); wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        require(RegisterClassW(&wc) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS, "Progress window registration failed");
        window = CreateWindowExW(0, wc.lpszClassName, L"Menkh — calculating job", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, 640, 220, nullptr, nullptr, wc.hInstance, this);
        require(window != nullptr, "Progress window unavailable");
        status = CreateWindowExW(0, L"STATIC", L"Starting calculation…", WS_CHILD | WS_VISIBLE, 20, 20, 590, 60, window, nullptr, wc.hInstance, nullptr);
        progress = CreateWindowExW(0, PROGRESS_CLASSW, L"", WS_CHILD | WS_VISIBLE | PBS_MARQUEE, 20, 95, 590, 20, window, nullptr, wc.hInstance, nullptr);
        cancel = CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 500, 135, 110, 28, window, reinterpret_cast<HMENU>(1), wc.hInstance, nullptr);
        require(status && progress && cancel, "Progress controls unavailable");
        if (!liveOutput.empty()) {
            pause=CreateWindowExW(0,L"BUTTON",paused?L"Resume calculation":L"Pause calculation",WS_CHILD|WS_VISIBLE|BS_PUSHBUTTON,20,135,155,28,window,reinterpret_cast<HMENU>(2),wc.hInstance,nullptr);
            follow=CreateWindowExW(0,L"BUTTON",L"Follow latest (uncheck to seek)",WS_CHILD|WS_VISIBLE|BS_AUTOCHECKBOX,185,135,300,28,window,reinterpret_cast<HMENU>(3),wc.hInstance,nullptr);
            require(pause && follow,"Live controls unavailable");SendMessageW(follow,BM_SETCHECK,BST_CHECKED,0);EnableWindow(pause,FALSE);
        }
        SendMessageW(progress, PBM_SETMARQUEE, TRUE, 80); ShowWindow(window, SW_SHOW); UpdateWindow(window);
    }
    void update(const Json &p) {
        if (cancelled || !p.is_object() || p.value("version", 0) != 1) return;
        try {
            const auto done = p.at("completed_operations").get<uint64_t>(), total = p.at("total_operations").get<uint64_t>();
            if (done > total) return;
            const auto phase = p.at("phase").get<std::string>();
            std::wstring label;
            if (phase == "cutting") {
                label = L"Cutting: " + std::to_wstring(done) + L" / " + std::to_wstring(total) + L" operations";
                if (!p.at("operation").is_null()) label += L"\n" + wide(p.at("operation").get<std::string>()).substr(0, 200);
                SendMessageW(progress, PBM_SETMARQUEE, FALSE, 0);
                SetWindowLongPtrW(progress, GWL_STYLE, GetWindowLongPtrW(progress, GWL_STYLE) & ~PBS_MARQUEE);
                SendMessageW(progress, PBM_SETRANGE32, 0, 1000); SendMessageW(progress, PBM_SETPOS, total ? WPARAM(done * 1000 / total) : 0, 0);
            } else {
                label = phase == "finalizing" ? L"Writing result and inspection data…" : phase == "complete" ? L"Loading result…" : L"Preparing stock, target and fixtures…";
            }
            SetWindowTextW(status, label.c_str());
        } catch (...) { /* Ignore incomplete/unrecognized progress, never the process exit code. */ }
    }
};
struct LiveHooks {
    bool enabled=false, startPaused=false;
    fs::path sourceJob;
    std::function<void(const fs::path &, RunWindow &)> update;
};
// The C job API requires a fresh output directory. Keep the launch copy in a
// unique temporary file until the worker is finished, then retain it for audit.
struct LiveJobCopy {
    fs::path path, output;
    ~LiveJobCopy() { if(!path.empty()){std::error_code ec;fs::copy_file(path,output/"live-job.json",fs::copy_options::overwrite_existing,ec);fs::remove(path,ec);} }
    void create(Json config, const fs::path &destination) {
        wchar_t directory[32768],name[MAX_PATH];
        const DWORD n=GetTempPathW(32768,directory);require(n && n<32768,"Cannot locate temporary directory");
        require(GetTempFileNameW(directory,L"mnk",0,name)!=0,"Cannot create live launch copy");
        path=name;output=destination;
        std::ofstream file(path);file<<config.dump();require(bool(file),"Cannot write live launch copy");
    }
};
inline std::optional<fs::path> calculateLibrary(const fs::path &job, const fs::path &library, const fs::path &output, const fs::path &cwd, int cancelAfter, LiveHooks *live = nullptr) {
    struct Module { HMODULE h=nullptr; ~Module(){if(h)FreeLibrary(h);} } module;
    module.h=LoadLibraryExW(library.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    require(module.h!=nullptr,"Cannot load selected engine library");
    const auto run=reinterpret_cast<decltype(&menkh_run_job_v1)>(GetProcAddress(module.h,"menkh_run_job_v1"));
    const auto version=reinterpret_cast<decltype(&menkh_abi_version)>(GetProcAddress(module.h,"menkh_abi_version"));
    require(run && version && version()==1,"Incompatible engine job API");
    struct State {
        std::atomic<bool> cancel{false},finished{false};
        std::atomic<uint32_t> phase{0};
        std::atomic<uint64_t> done{0},total{0};
        menkh_status result=MENKH_INVALID_ARGUMENT;
    } state;
    RunWindow ui;if(live){ui.liveOutput=output;ui.paused=live->startPaused;}ui.create();
    if(cancelAfter==0){ui.stop();state.cancel=true;}
    const auto input=job.u8string(),destination=output.u8string(),base=cwd.u8string();
    {
        std::ofstream file(output/"launch.json");
        file<<Json{{"mode","library"},{"viewer_pid",GetCurrentProcessId()},{"library",library.u8string()},{"job",input},{"source_job",live?live->sourceJob.u8string():input},{"working_directory",base}}.dump(2);
        require(bool(file),"Cannot write library launch metadata");
    }
    struct Worker {
        State &state;
        std::function<void()> task;
        WinHandle thread;
        Worker(State &s, std::function<void()> f):state(s),task(std::move(f)) {
            // The whole-job DLL uses nested Windows long-path conversion buffers.
            // Reserve the same 16 MiB as a Zig thread, rather than inheriting the
            // MSVC host's 1 MiB default. Pages are committed on demand.
            thread.value=reinterpret_cast<HANDLE>(_beginthreadex(nullptr,16*1024*1024,
                [](void *p)->unsigned {static_cast<Worker*>(p)->task();return 0;},this,
                STACK_SIZE_PARAM_IS_A_RESERVATION,nullptr));
            require(thread.value!=nullptr,"Cannot start calculation worker");
        }
        void join(){require(WaitForSingleObject(thread.value,INFINITE)==WAIT_OBJECT_0,"Cannot join calculation worker");}
        ~Worker(){state.cancel=true;if(thread.value && thread.value!=INVALID_HANDLE_VALUE)WaitForSingleObject(thread.value,INFINITE);}
    } worker{state,[&]{
        state.result=run(input.c_str(),destination.c_str(),base.c_str(),[](void *context,uint32_t phase,uint64_t done,uint64_t total)->uint32_t {
            auto &s=*static_cast<State*>(context);s.total=total;s.done=done;s.phase=phase;return s.cancel?1u:0u;
        },&state);
        state.finished=true;
    }};
    const auto began=std::chrono::steady_clock::now();
    while(!state.finished){
        MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) {if(message.message==WM_QUIT)ui.stop();else{TranslateMessage(&message);DispatchMessageW(&message);}}
        if(cancelAfter>0 && std::chrono::steady_clock::now()-began>=std::chrono::milliseconds(cancelAfter))ui.stop();
        if(ui.cancelled)state.cancel=true;
        const char *phase=state.phase==3?"cutting":state.phase==4?"finalizing":state.phase==5?"complete":"preparing";
        ui.update(Json{{"version",1},{"phase",phase},{"completed_operations",state.done.load()},{"total_operations",state.total.load()},{"operation",nullptr}});
        ui.liveControls();
        if(live && live->update)live->update(output,ui);
        MsgWaitForMultipleObjects(0,nullptr,FALSE,50,QS_ALLINPUT);
    }
    worker.join();
    if(state.result==MENKH_CANCELLED || ui.cancelled)return std::nullopt;
    if(state.result!=MENKH_OK)throw std::runtime_error("Library calculation failed: "+tail(output/"simulation.log"));
    require(fs::is_regular_file(output/"voxel-animation.json"),"Library result manifest missing");
    return output/"voxel-animation.json";
}
inline std::optional<fs::path> calculateJob(const fs::path &input, fs::path engine, fs::path output, fs::path cwd, int cancelAfter, fs::path library = {}, LiveHooks *live = nullptr) {
    const bool explicitEngine=!engine.empty();
    if(library.empty() && !explicitEngine && fs::is_regular_file(viewerExecutable().parent_path()/"menkh.dll"))library=viewerExecutable().parent_path()/"menkh.dll";
    if(library.empty())engine = findEngine(engine);
    else {require(!explicitEngine,"Choose --engine or --library");library=fs::absolute(library);require(fs::is_regular_file(library),"Selected engine library does not exist");} auto job = fs::absolute(input);
    cwd = cwd.empty() ? job.parent_path() : fs::absolute(cwd);
    require(fs::is_directory(cwd), "Job working directory does not exist");
    if (output.empty()) {
        wchar_t local[32768]; const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", local, 32768);
        const auto root = n && n < 32768 ? fs::path(local) : fs::temp_directory_path();
        output = root / "Menkh" / "runs" / (std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    }
    output = fs::absolute(output);
    require(!fs::exists(output), "Job output already exists; choose a new --job-output directory");
    fs::create_directories(output);
    std::cout << "Simulation output: " << output.u8string() << '\n';
    LiveJobCopy copy;
    if(live) {
        live->sourceJob=job;
        auto config=Json::parse(read(job,64<<20));
        if(!config.contains("live_inspection") || config["live_inspection"].is_null())config["live_inspection"]=Json::object();
        live->startPaused=config.at("live_inspection").value("start_paused",false);
        copy.create(std::move(config),output);job=copy.path;
    }
    if(!library.empty())return calculateLibrary(job,library,output,cwd,cancelAfter,live);
    WinHandle group, log, inputHandle, process, thread;
    group.value = CreateJobObjectW(nullptr, nullptr); require(group.value != nullptr, "Cannot create calculation process group");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    require(SetInformationJobObject(group.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) != FALSE, "Cannot configure calculation process group");
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    log.value = CreateFileW((output / "simulation.log").c_str(), GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    require(log.value != INVALID_HANDLE_VALUE, "Cannot create simulation log");
    inputHandle.value = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    require(inputHandle.value != INVALID_HANDLE_VALUE, "Cannot open calculation input");
    STARTUPINFOW start{}; start.cb = sizeof(start); start.dwFlags = STARTF_USESTDHANDLES; start.hStdOutput = start.hStdError = log.value; start.hStdInput = inputHandle.value;
    PROCESS_INFORMATION info{};
    auto command = quote(engine.wstring()) + L" job " + quote(job.wstring()) + L" --out " + quote(output.wstring()) + L" --progress " + quote((output / "progress.jsonl").wstring());
    require(CreateProcessW(engine.c_str(), command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, cwd.c_str(), &start, &info) != FALSE, "Cannot start simulation engine");
    process.value = info.hProcess; thread.value = info.hThread;
    if (!AssignProcessToJobObject(group.value, process.value)) { TerminateProcess(process.value, 1); throw std::runtime_error("Cannot supervise simulation process"); }
    {
        std::ofstream launch(output / "launch.json");
        launch << Json{{"engine_pid",info.dwProcessId},{"engine",engine.u8string()},{"job",job.u8string()},{"source_job",live?live->sourceJob.u8string():job.u8string()},{"working_directory",cwd.u8string()}}.dump(2);
        require(bool(launch), "Cannot write launch metadata");
    }
    RunWindow ui; ui.group = group.value;if(live){ui.liveOutput=output;ui.paused=live->startPaused;} ui.create();
    if (cancelAfter == 0) ui.stop();
    if(cancelAfter != 0 || live)require(ResumeThread(thread.value) != DWORD(-1), "Cannot resume simulation process");
    const auto began = std::chrono::steady_clock::now();
    while (WaitForSingleObject(process.value, 0) == WAIT_TIMEOUT) {
        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { if (message.message == WM_QUIT) ui.stop(); else { TranslateMessage(&message); DispatchMessageW(&message); } }
        if (cancelAfter > 0 && std::chrono::steady_clock::now() - began >= std::chrono::milliseconds(cancelAfter)) ui.stop();
        ui.update(lastProgress(output / "progress.jsonl"));
        ui.liveControls();
        if(live && live->update)live->update(output,ui);
        HANDLE handle = process.value; MsgWaitForMultipleObjects(1, &handle, FALSE, 100, QS_ALLINPUT);
    }
    if (ui.cancelled) { std::cerr << "Simulation cancelled; partial output retained at " << output.u8string() << '\n'; return std::nullopt; }
    DWORD code = 1; require(GetExitCodeProcess(process.value, &code) != FALSE, "Cannot read engine exit status");
    if (code != 0) throw std::runtime_error("Simulation failed (exit " + std::to_string(code) + "). Log: " + (output / "simulation.log").u8string() + "\n" + tail(output / "simulation.log").substr(0, 4000));
    const auto progress = lastProgress(output / "progress.jsonl");
    require(progress.is_object() && progress.value("phase", "") == "complete", "Engine did not publish a complete result; update the engine binary");
    require(fs::is_regular_file(output / "voxel-animation.json"), "Engine result manifest missing");
    return output / "voxel-animation.json";
}
} // namespace menkh
