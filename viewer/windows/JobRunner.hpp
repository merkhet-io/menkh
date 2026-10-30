#pragma once
#include "History.hpp"
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <chrono>
#include <optional>
#include <iostream>
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
struct RunWindow {
    HWND window = nullptr, status = nullptr, progress = nullptr, cancel = nullptr;
    HANDLE group = nullptr; bool cancelled = false;
    ~RunWindow() { if (window) DestroyWindow(window); }
    void stop() {
        cancelled = true;
        if (group) TerminateJobObject(group, 2);
        if (cancel) EnableWindow(cancel, FALSE);
        if (status) SetWindowTextW(status, L"Cancelling calculation…");
    }
    static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM w, LPARAM l) {
        auto *s = reinterpret_cast<RunWindow *>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) { s = static_cast<RunWindow *>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(s)); }
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
inline std::optional<fs::path> calculateJob(const fs::path &input, fs::path engine, fs::path output, fs::path cwd, int cancelAfter) {
    engine = findEngine(engine); const auto job = fs::absolute(input);
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
        launch << Json{{"engine_pid",info.dwProcessId},{"engine",engine.u8string()},{"job",job.u8string()},{"working_directory",cwd.u8string()}}.dump(2);
        require(bool(launch), "Cannot write launch metadata");
    }
    RunWindow ui; ui.group = group.value; ui.create();
    if (cancelAfter == 0) ui.stop(); else require(ResumeThread(thread.value) != DWORD(-1), "Cannot resume simulation process");
    const auto began = std::chrono::steady_clock::now();
    while (WaitForSingleObject(process.value, 0) == WAIT_TIMEOUT) {
        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) { if (message.message == WM_QUIT) ui.stop(); else { TranslateMessage(&message); DispatchMessageW(&message); } }
        if (cancelAfter > 0 && std::chrono::steady_clock::now() - began >= std::chrono::milliseconds(cancelAfter)) ui.stop();
        ui.update(lastProgress(output / "progress.jsonl"));
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
