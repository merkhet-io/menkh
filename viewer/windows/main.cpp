#include "Renderer.hpp"
#include <chrono>
#include <commctrl.h>
#include <iostream>
#include <memory>
#include <windowsx.h>
#pragma comment(lib, "comctl32.lib")
using namespace menkh;
struct App {
    History history;
    Camera camera;
    std::unique_ptr<Renderer> renderer;
    HWND window = nullptr, viewport = nullptr, slider = nullptr, playButton = nullptr,
         status = nullptr;
    bool playing = false, dragging = false, panning = false, dirty = true;
    POINT last{};
    std::chrono::steady_clock::time_point tick{};
    explicit App(const fs::path &file) : history(file) { camera.reset(history); }
    void seek(size_t value) {
        playing = false;
        history.seek(value);
        dirty = true;
        refresh();
    }
    void refresh() {
        SendMessageW(slider, TBM_SETPOS, TRUE, LPARAM(history.frame));
        SetWindowTextW(playButton, playing ? L"Pause" : L"Play");
        std::wostringstream text;
        text << L"Frame " << history.frame << L" / " << history.steps.size() << L"   |   "
             << history.h * 1000 << L" um   |   "
             << (history.frame ? history.steps[history.frame - 1].occupied : history.initial)
             << L" occupied   |   motion budget " << history.tolerance << L" mm";
        if (history.frame && history.steps[history.frame - 1].unsupportedCutter)
            text << L"   |   non-flat cutter display unavailable";
        SetWindowTextW(status, text.str().c_str());
    }
    void layout() {
        RECT r{};
        GetClientRect(window, &r);
        const int width = std::max(1L, r.right), height = std::max(1L, r.bottom - 84);
        MoveWindow(viewport, 0, 0, width, height, TRUE);
        MoveWindow(playButton, 8, height + 6, 64, 26, TRUE);
        MoveWindow(GetDlgItem(window, 102), 78, height + 6, 64, 26, TRUE);
        MoveWindow(slider, 148, height + 3, std::max(1, width - 156), 30, TRUE);
        MoveWindow(status, 8, height + 39, width - 16, 20, TRUE);
        dirty = true;
    }
    void key(WPARAM key) {
        if (key == VK_SPACE) {
            playing = !playing;
            if (playing && history.frame == history.steps.size())
                history.seek(0);
            tick = std::chrono::steady_clock::now();
        } else if (key == VK_LEFT)
            seek(history.frame ? history.frame - 1 : 0);
        else if (key == VK_RIGHT)
            seek(std::min(history.steps.size(), history.frame + 1));
        else if (key == VK_HOME)
            seek(0);
        else if (key == VK_END)
            seek(history.steps.size());
        else if (key == 'R')
            camera.reset(history);
        else if (key == 'B')
            camera.dark = !camera.dark;
        else if (key == 'T')
            camera.tool = !camera.tool;
        else if (key == 'A')
            camera.antialias = !camera.antialias;
        else if (key == VK_OEM_4)
            camera.section = std::max(.02f, camera.section - .05f);
        else if (key == VK_OEM_6)
            camera.section = std::min(1.f, camera.section + .05f);
        dirty = true;
        refresh();
    }
    void mouse(UINT message, WPARAM w, LPARAM l) {
        if (message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN) {
            SetFocus(viewport);
            SetCapture(viewport);
            dragging = true;
            panning = message == WM_RBUTTONDOWN;
            last = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
        } else if (message == WM_LBUTTONUP || message == WM_RBUTTONUP) {
            dragging = false;
            ReleaseCapture();
        } else if (message == WM_CAPTURECHANGED)
            dragging = false;
        else if (message == WM_MOUSEMOVE && dragging) {
            POINT now{GET_X_LPARAM(l), GET_Y_LPARAM(l)};
            const float dx = float(now.x - last.x), dy = float(now.y - last.y);
            last = now;
            if (panning) {
                Vec f{-std::cos(camera.elevation) * std::cos(camera.yaw),
                      -std::cos(camera.elevation) * std::sin(camera.yaw),
                      -std::sin(camera.elevation)};
                auto right = unit(cross(f, Vec{0, 0, 1})), up = cross(right, f);
                camera.target = add(camera.target, add(mul(right, -dx * camera.distance * .0015f),
                                                       mul(up, dy * camera.distance * .0015f)));
            } else {
                camera.yaw -= dx * .008f;
                camera.elevation = std::clamp(camera.elevation + dy * .008f, -1.5f, 1.5f);
            }
            dirty = true;
        } else if (message == WM_MOUSEWHEEL) {
            camera.distance =
                std::clamp(camera.distance * std::exp(-float(GET_WHEEL_DELTA_WPARAM(w)) * .001f),
                           history.h, 100000.f);
            dirty = true;
        }
    }
    void draw() {
        if (!dirty || IsIconic(window))
            return;
        RECT r{};
        GetClientRect(viewport, &r);
        if (r.right <= 0 || r.bottom <= 0)
            return;
        renderer->resize(uint32_t(r.right), uint32_t(r.bottom));
        renderer->render(history, camera);
        dirty = false;
    }
};
LRESULT CALLBACK procedure(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    auto *app = reinterpret_cast<App *>(GetWindowLongPtrW(w, GWLP_USERDATA));
    if (msg == WM_NCCREATE) {
        app = static_cast<App *>(reinterpret_cast<CREATESTRUCTW *>(lp)->lpCreateParams);
        SetWindowLongPtrW(w, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    }
    if (!app)
        return DefWindowProcW(w, msg, wp, lp);
    try {
        switch (msg) {
        case WM_SIZE:
            if (w == app->window && app->viewport)
                app->layout();
            return 0;
        case WM_PAINT: {
            PAINTSTRUCT p{};
            BeginPaint(w, &p);
            EndPaint(w, &p);
            app->dirty = true;
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_COMMAND:
            if (LOWORD(wp) == 101)
                app->key(VK_SPACE);
            else if (LOWORD(wp) == 102)
                app->key('R');
            SetFocus(app->viewport);
            return 0;
        case WM_HSCROLL:
            app->seek(size_t(SendMessageW(app->slider, TBM_GETPOS, 0, 0)));
            return 0;
        case WM_KEYDOWN:
            app->key(wp);
            return 0;
        case WM_LBUTTONDOWN:
        case WM_RBUTTONDOWN:
        case WM_LBUTTONUP:
        case WM_RBUTTONUP:
        case WM_CAPTURECHANGED:
        case WM_MOUSEMOVE:
        case WM_MOUSEWHEEL:
            app->mouse(msg, wp, lp);
            return 0;
        case WM_CLOSE:
            DestroyWindow(w);
            return 0;
        case WM_DESTROY:
            if (w == app->window)
                PostQuitMessage(0);
            return 0;
        }
    } catch (const std::exception &e) {
        MessageBoxA(w, e.what(), "Menkh viewer error", MB_OK | MB_ICONERROR);
        PostQuitMessage(1);
        return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}
int wmain(int argc, wchar_t **argv) {
    try {
        if (argc < 2) {
            std::cerr << "menkh-viewer.exe HISTORY.json [--warp] [--debug] [--verify-history] "
                         "[--smoke DIR] [--snapshot FILE.ppm] [--window-smoke DIR] [--frame N]\n";
            return 1;
        }
        bool warp = false, debug = false, verify = false;
        fs::path smoke, snapshot, windowSmoke;
        size_t frame = 0;
        for (int i = 2; i < argc; i++) {
            std::wstring a = argv[i];
            if (a == L"--warp")
                warp = true;
            else if (a == L"--debug")
                debug = true;
            else if (a == L"--verify-history")
                verify = true;
            else if ((a == L"--smoke" || a == L"--snapshot" || a == L"--frame" ||
                      a == L"--window-smoke") &&
                     i + 1 < argc) {
                if (a == L"--window-smoke")
                    windowSmoke = argv[++i];
                else if (a == L"--smoke")
                    smoke = argv[++i];
                else if (a == L"--snapshot")
                    snapshot = argv[++i];
                else {
                    std::wstring value = argv[++i];
                    size_t used = 0;
                    frame = std::stoull(value, &used);
                    require(used == value.size(), "Invalid frame");
                }
            } else
                throw std::runtime_error("Unknown or incomplete option");
        }
        App app{fs::path(argv[1])};
        if (verify) {
            app.history.verify();
            std::cout << "Byte-exact forward/backward history verified\n";
            if (smoke.empty() && snapshot.empty() && windowSmoke.empty())
                return 0;
        }
        wchar_t exe[32768];
        const DWORD len = GetModuleFileNameW(nullptr, exe, 32768);
        require(len > 0 && len < 32768, "Cannot locate viewer executable");
        app.renderer = std::make_unique<Renderer>(
            app.history, fs::path(exe).parent_path() / "Voxel.hlsl", warp, debug);
        // Do not mix wide and narrow streams on stdout (also redirected by CI).
        std::cout << "D3D12 adapter: " << fs::path(app.renderer->adapterName()).u8string() << '\n';
        if (!smoke.empty()) {
            fs::create_directories(smoke);
            app.renderer->resize(640, 480);
            const size_t frames[] = {0, app.history.steps.size() / 2, app.history.steps.size(), 0};
            const char *names[] = {"initial.ppm", "middle.ppm", "final.ppm", "rewound.ppm"};
            for (size_t i = 0; i < 4; i++) {
                app.history.seek(frames[i]);
                app.renderer->render(app.history, app.camera);
                app.renderer->snapshot(smoke / names[i]);
            }
            require(read(smoke / "initial.ppm") == read(smoke / "rewound.ppm"),
                    "Rendered rewind differs");
            require(read(smoke / "initial.ppm") != read(smoke / "final.ppm"),
                    "Initial and final render unexpectedly identical");
            std::ofstream report(smoke / "validation.txt");
            report << "D3D12 WARP/hardware render completed; initial/middle/final/rewound images "
                      "saved.\nByte-exact rendered rewind passed.\n";
            require(bool(report), "Cannot write validation report");
            return 0;
        }
        app.history.seek(frame);
        if (!snapshot.empty()) {
            app.renderer->resize(1280, 900);
            app.renderer->render(app.history, app.camera);
            app.renderer->snapshot(snapshot);
            return 0;
        }
        SetProcessDPIAware();
        INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_BAR_CLASSES};
        require(InitCommonControlsEx(&controls) != FALSE, "Initialize controls failed");
        WNDCLASSW wc{};
        wc.lpfnWndProc = procedure;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"MenkhD3D12";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        require(RegisterClassW(&wc) != 0, "Register window class failed");
        app.window =
            CreateWindowExW(0, wc.lpszClassName,
                            L"Menkh - D3D12 voxel viewer | drag: orbit, right drag: pan, wheel: "
                            L"zoom | Space, arrows, R, B, T, A, [ ]",
                            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT,
                            1280, 960, nullptr, nullptr, wc.hInstance, &app);
        require(app.window != nullptr, "Create window failed");
        app.viewport = CreateWindowExW(0, wc.lpszClassName, L"", WS_CHILD | WS_VISIBLE, 0, 0, 1, 1,
                                       app.window, nullptr, wc.hInstance, &app);
        app.playButton =
            CreateWindowExW(0, L"BUTTON", L"Play", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 64,
                            26, app.window, reinterpret_cast<HMENU>(101), wc.hInstance, nullptr);
        CreateWindowExW(0, L"BUTTON", L"Reset", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 64, 26,
                        app.window, reinterpret_cast<HMENU>(102), wc.hInstance, nullptr);
        app.slider = CreateWindowExW(0, TRACKBAR_CLASSW, L"", WS_CHILD | WS_VISIBLE | TBS_NOTICKS,
                                     0, 0, 1, 1, app.window, nullptr, wc.hInstance, nullptr);
        app.status = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, 0, 0, 1, 1,
                                     app.window, nullptr, wc.hInstance, nullptr);
        require(app.viewport && app.playButton && app.slider && app.status,
                "Create controls failed");
        SendMessageW(app.slider, TBM_SETRANGE, TRUE, MAKELPARAM(0, 0));
        SendMessageW(app.slider, TBM_SETRANGEMAX, TRUE, LPARAM(app.history.steps.size()));
        app.renderer->attach(app.viewport);
        app.layout();
        app.refresh();
        ShowWindow(app.window, SW_SHOW);
        SetFocus(app.viewport);
        if (!windowSmoke.empty()) {
            fs::create_directories(windowSmoke);
            SetWindowPos(app.window, nullptr, 0, 0, 960, 720, SWP_NOMOVE | SWP_NOZORDER);
            SendMessageW(app.slider, TBM_SETPOS, TRUE, LPARAM(app.history.steps.size()));
            SendMessageW(app.window, WM_HSCROLL, SB_THUMBPOSITION,
                         reinterpret_cast<LPARAM>(app.slider));
            require(app.history.frame == app.history.steps.size(),
                    "Slider did not scrub to final frame");
            app.draw();
            app.renderer->snapshot(windowSmoke / "window-final.ppm");
            std::cerr << "Window smoke: final snapshot saved\n";
            SendMessageW(app.viewport, WM_KEYDOWN, VK_HOME, 0);
            require(app.history.frame == 0, "Home key failed");
            app.draw();
            std::cerr << "Window smoke: Home rendered\n";
            SendMessageW(app.viewport, WM_KEYDOWN, VK_END, 0);
            require(app.history.frame == app.history.steps.size(), "End key failed");
            SendMessageW(app.viewport, WM_KEYDOWN, 'R', 0);
            app.draw();
            std::cerr << "Window smoke: End and reset rendered\n";
            DestroyWindow(app.window);
            std::cerr << "Window smoke: window destroyed\n";
            std::cout << "Window, swapchain, resize, slider and Home/End controls passed\n";
            app.renderer.reset();
            std::cerr << "Window smoke: renderer released\n";
            return 0;
        }
        MSG msg{};
        bool running = true;
        while (running) {
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) {
                    running = false;
                    break;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            if (!running)
                break;
            const auto now = std::chrono::steady_clock::now();
            if (app.playing && now - app.tick >= std::chrono::milliseconds(80)) {
                if (app.history.frame < app.history.steps.size())
                    app.history.seek(app.history.frame + 1);
                else
                    app.playing = false;
                app.tick = now;
                app.dirty = true;
                app.refresh();
            }
            app.draw();
            MsgWaitForMultipleObjects(0, nullptr, FALSE, app.playing ? 8 : 50, QS_ALLINPUT);
        }
        return int(msg.wParam);
    } catch (const std::exception &e) {
        std::cerr << "Menkh viewer: " << e.what() << '\n';
        return 1;
    }
}
