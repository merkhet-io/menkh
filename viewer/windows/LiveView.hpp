#pragma once
// Included after App/openWindow. The UI thread owns histories, leases and D3D12;
// the engine worker never exposes a mutable grid to the renderer.
class LiveView {
    bool warp, debug;
    fs::path evidence;
    std::unique_ptr<LiveLease> lease;
    std::unique_ptr<App> app;
    uint64_t sequence=0;
    std::chrono::steady_clock::time_point loaded{};
    bool following=true;
    static double ms(std::chrono::steady_clock::duration d){return std::chrono::duration<double,std::milli>(d).count();}
    static void bytes(const fs::path &path,const void *data,size_t size){std::ofstream f(path,std::ios::binary);f.write(static_cast<const char*>(data),std::streamsize(size));require(bool(f),"Cannot write live evidence");}
public:
    LiveView(bool w,bool d,fs::path e):warp(w),debug(d),evidence(std::move(e)){}
    ~LiveView(){if(app){app->renderer.reset();if(app->window)DestroyWindow(app->window);}app.reset();lease.reset();}
    void update(const fs::path &output,RunWindow &controls) {
        const bool follow=controls.following();
        if(app)app->advance();
        if(follow && !following && app)ShowWindow(app->window,SW_SHOW);
        following=follow;
        if(!follow || std::chrono::steady_clock::now()-loaded<std::chrono::milliseconds(500))return;
        auto incoming=nextLiveWindow(output,sequence);if(!incoming)return;
        const auto began=std::chrono::steady_clock::now();
        History history(incoming->manifest);
        if(!evidence.empty())history.verify();
        history.seek(history.steps.size());
        const auto sought=std::chrono::steady_clock::now();
        auto renderer=std::make_unique<Renderer>(history,viewerExecutable().parent_path()/"Voxel.hlsl",warp,debug);
        const auto prepared=std::chrono::steady_clock::now();
        renderer->uploadMaterial(history);
        const auto uploaded=std::chrono::steady_clock::now();
        if(!app) {
            app=std::make_unique<App>(incoming->manifest);app->live=true;
            app->history=std::move(history);app->renderer=std::move(renderer);
            openWindow(*app);
            // Scrubbing implicitly holds the current window rather than having
            // the next publication undo the user's camera/history inspection.
            app->onScrub=[box=controls.follow] {SendMessageW(box,BM_SETCHECK,BST_UNCHECKED,0);};
        } else {
            app->renderer.reset();app->history=std::move(history);app->renderer=std::move(renderer);
            app->renderer->attach(app->viewport);
        }
        lease=std::move(incoming->lease);sequence=incoming->pointer.at("sequence").get<uint64_t>();
        const auto first=incoming->metadata.at("first_operation").get<uint64_t>(),end=incoming->metadata.at("completed_operations").get<uint64_t>();
        app->playing=false;app->dirty=true;
        app->liveBanner=L"LIVE "+std::to_wstring(first)+L"…"+std::to_wstring(end)+L" | ";
        SetWindowTextW(app->window,(L"Menkh — live material · retained operations "+std::to_wstring(first)+L"…"+std::to_wstring(end)).c_str());
        SendMessageW(app->slider,TBM_SETRANGEMAX,TRUE,LPARAM(app->history.steps.size()));
        app->refresh();app->draw();
        const auto drawn=std::chrono::steady_clock::now();loaded=drawn;
        PROCESS_MEMORY_COUNTERS memory{};memory.cb=sizeof(memory);require(GetProcessMemoryInfo(GetCurrentProcess(),&memory,sizeof(memory))!=FALSE,"Cannot query viewer memory");
        const auto &h=app->history;
        Json record={{"sequence",sequence},{"first_operation",first},{"completed_operations",end},{"load_seek_ms",ms(sought-began)},{"renderer_setup_ms",ms(prepared-sought)},{"upload_ms",ms(uploaded-prepared)},{"attach_render_ms",ms(drawn-uploaded)},
            {"cpu_material_capacity_bytes",h.blocks.capacity()*4+h.pool.capacity()*8+h.slotOwner.capacity()*4},
            {"retained_delta_bytes",uint64_t(0)},{"process_peak_rss_bytes",memory.PeakWorkingSetSize},{"publication",incoming->pointer},{"adapter",fs::path(app->renderer->adapterName()).u8string()},{"verification_enabled",!evidence.empty()}};
        record["d3d12_allocations"]=app->renderer->materialMemory();
        record["history_metadata_capacity_bytes"]=h.steps.capacity()*sizeof(Step);
        record["dirty_scratch_capacity_bytes"]=(h.dirtyBlocks.capacity()+h.dirtySlots.capacity())*sizeof(size_t);
        for(const auto &step:h.steps){record["retained_delta_bytes"]=record["retained_delta_bytes"].get<uint64_t>()+step.bytes;record["history_metadata_capacity_bytes"]=record["history_metadata_capacity_bytes"].get<uint64_t>()+step.stage.capacity()+step.file.native().capacity()*sizeof(fs::path::value_type);}
        if(!evidence.empty()) {
            const auto dir=evidence/("window-"+std::to_string(sequence));fs::create_directories(dir);
            std::ofstream meta(dir/"window.json");meta<<incoming->metadata.dump(2);require(bool(meta),"Cannot write window metadata");
            bytes(dir/"final.blocks",h.blocks.data(),h.blocks.size()*4);bytes(dir/"final.pool",h.pool.data(),h.pool.size()*8);
            // Capture the actual GPU result, rewind and return to the same frame.
            app->renderer->snapshot(dir/"latest.ppm");
            app->history.seek(0);app->dirty=true;app->draw();app->renderer->snapshot(dir/"base.ppm");
            app->history.seek(app->history.steps.size());app->dirty=true;app->draw();app->renderer->snapshot(dir/"replayed.ppm");
            require(read(dir/"latest.ppm")==read(dir/"replayed.ppm"),"Live D3D12 replay pixels differ");
            record["render_replay_exact"]=true;app->refresh();
        }
        require(GetProcessMemoryInfo(GetCurrentProcess(),&memory,sizeof(memory))!=FALSE,"Cannot query viewer memory");
        record["process_peak_rss_bytes"]=memory.PeakWorkingSetSize;
        std::ofstream log(output/"live-viewer.jsonl",std::ios::app);log<<record.dump()<<'\n';require(bool(log),"Cannot write live viewer metrics");
    }
    void finish(const std::string &message,bool automated) {
        if(!app || automated)return;
        app->liveBanner=wide(message)+L" | ";app->playing=false;app->refresh();
        SetWindowTextW(app->window,L"Menkh — stopped calculation · last consistent window");
        app->onScrub={};app->live=false;ShowWindow(app->window,SW_SHOW);
        MSG m{};bool running=true;
        while(running){while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){if(m.message==WM_QUIT){running=false;break;}TranslateMessage(&m);DispatchMessageW(&m);}if(running){app->advance();MsgWaitForMultipleObjects(0,nullptr,FALSE,20,QS_ALLINPUT);}}
        app->window=nullptr; // WM_CLOSE already released renderer and destroyed HWND.
    }
};
