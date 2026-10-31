import AppKit
import Foundation
import Darwin

/// Runs the engine out of process; optional leased live windows are independent
/// of the final archive. Cancel/failure retains the last consistent live window.
final class JobRunner:NSObject,NSWindowDelegate {
    let process=Process()
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:260),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    let status=NSTextField(wrappingLabelWithString:"Starting calculation…")
    let progress=NSProgressIndicator()
    let button=NSButton(title:"Cancel",target:nil,action:nil)
    var output=URL(fileURLWithPath:"/")
    var log:FileHandle?
    var timer:Timer?
    var cancelled=false
    var quitRequested=false
    var finished=false
    var onSuccess:((URL)->Void)?
    var automated=false
    var live:LiveInspection?
    let follow=NSButton(checkboxWithTitle:"Follow latest (uncheck to seek)",target:nil,action:nil)
    let pause=NSButton(title:"Pause calculation",target:nil,action:nil)
    var paused=false
    var isRunning:Bool {!finished && process.isRunning}
    static func argument(_ name:String) throws -> String? {
        let args=CommandLine.arguments
        guard let i=args.firstIndex(of:name) else {return nil}
        guard i+1<args.count else {throw MeshError.invalidOBJ("Missing value for \(name)")}
        return args[i+1]
    }
    static func tail(_ file:URL) -> Data {
        guard let handle=try? FileHandle(forReadingFrom:file) else {return Data()}
        defer {try? handle.close()}
        do {let end=try handle.seekToEnd();try handle.seek(toOffset:end>65536 ? end-65536:0);return try handle.read(upToCount:65536) ?? Data()}catch{return Data()}
    }
    static func progressRecord(_ file:URL) -> [String:Any]? {
        let data=tail(file)
        guard let end=data.lastIndex(of:10),end>data.startIndex else {return nil}
        let prefix=data[..<end];let start=prefix.lastIndex(of:10).map {$0+1} ?? prefix.startIndex
        return (try? JSONSerialization.jsonObject(with:Data(prefix[start...]))) as? [String:Any]
    }
    func start(_ input:URL,success:@escaping (URL)->Void) throws {
        onSuccess=success
        let args=CommandLine.arguments
        automated=args.contains("--run-only") || args.contains("--snapshot") || args.contains("--render-bench") || args.contains("--verify-history") || args.contains("--cancel-after-ms")
        let job=input.standardizedFileURL
        let executable=URL(fileURLWithPath:try Self.argument("--engine") ?? URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("menkh").path).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw MeshError.invalidOBJ("Simulation engine not found. Place menkh beside the viewer or use --engine PATH.")}
        let cwd=try Self.argument("--working-dir").map {URL(fileURLWithPath:$0).standardizedFileURL} ?? job.deletingLastPathComponent()
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:cwd.path,isDirectory:&directory),directory.boolValue else {throw MeshError.invalidOBJ("Job working directory does not exist")}
        if let path=try Self.argument("--job-output") {output=URL(fileURLWithPath:path).standardizedFileURL}
        else {output=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Menkh/runs/\(UUID().uuidString)")}
        guard !FileManager.default.fileExists(atPath:output.path) else {throw MeshError.invalidOBJ("Job output already exists; choose a new --job-output directory")}
        let cancelDelay:Double?
        if let raw=try Self.argument("--cancel-after-ms") {guard let value=Double(raw),value.isFinite,value>=0 else {throw MeshError.invalidOBJ("Invalid cancellation delay")};cancelDelay=value/1000} else {cancelDelay=nil}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let logURL=output.appendingPathComponent("simulation.log")
        guard FileManager.default.createFile(atPath:logURL.path,contents:Data()) else {throw MeshError.invalidOBJ("Cannot create simulation log")}
        log=try FileHandle(forWritingTo:logURL)
        process.executableURL=executable;process.currentDirectoryURL=cwd
        process.arguments=["job",job.path,"--out",output.path,"--progress",output.appendingPathComponent("progress.jsonl").path]
        if args.contains("--live") {
            guard var config=try JSONSerialization.jsonObject(with:Data(contentsOf:job)) as? [String:Any] else {throw MeshError.invalidOBJ("Expected a JSON job object")}
            if config["live_inspection"] == nil {config["live_inspection"]=[String:Any]()}
            paused=(config["live_inspection"] as? [String:Any])?["start_paused"] as? Bool ?? false
            pause.title=paused ? "Resume calculation":"Pause calculation"
            let liveJob=output.appendingPathComponent("live-job.json")
            try JSONSerialization.data(withJSONObject:config,options:[.sortedKeys]).write(to:liveJob)
            process.arguments![1]=liveJob.path
            live=LiveInspection(output:output)
        }
        process.standardOutput=log;process.standardError=log;process.standardInput=FileHandle.nullDevice
        window.isReleasedWhenClosed=false
        window.title="Menkh — calculating \(job.lastPathComponent)";window.delegate=self
        status.maximumNumberOfLines=5
        let location=NSTextField(wrappingLabelWithString:"Result and log: \(output.path)");location.isSelectable=true;location.maximumNumberOfLines=3
        progress.isIndeterminate=true;progress.style = .bar;progress.startAnimation(nil)
        button.target=self;button.action=#selector(cancelOrClose)
        let openLog=NSButton(title:"Open log",target:self,action:#selector(openLogFile))
        let buttons=NSStackView(views:[button,openLog])
        if live != nil {
            follow.state = .on;follow.target=self;follow.action=#selector(toggleFollow)
            pause.target=self;pause.action=#selector(toggleCalculation)
            buttons.addArrangedSubview(pause);buttons.addArrangedSubview(follow)
        }
        let stack=NSStackView(views:[status,progress,location,buttons]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24),status.widthAnchor.constraint(equalTo:stack.widthAnchor),location.widthAnchor.constraint(equalTo:stack.widthAnchor),progress.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        process.terminationHandler={ [weak self] _ in DispatchQueue.main.async {self?.complete()} }
        do {try process.run()}catch {finished=true;try? log?.close();window.close();throw error}
        do {
            let launch:[String:Any]=["engine_pid":process.processIdentifier,"engine":executable.path,"job":job.path,"working_directory":cwd.path]
            try JSONSerialization.data(withJSONObject:launch,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("launch.json"))
        } catch {cancel();throw error}
        print("Simulation output: \(output.path)")
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in self?.update() }
        if let delay=cancelDelay {DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in self?.cancel() }}
    }
    @objc func toggleFollow() {live?.following=follow.state == .on;if follow.state == .on {live?.window?.makeKeyAndOrderFront(nil)}else{live?.controller?.livePlaybackEnd=nil}}
    @objc func toggleCalculation() {
        guard !finished,live != nil else {return}
        do {
            let path=output.appendingPathComponent("live/pause")
            if paused {try FileManager.default.removeItem(at:path)}
            else {try Data().write(to:path)}
            paused.toggle();pause.title=paused ? "Resume calculation":"Pause calculation"
        } catch {status.stringValue="Cannot change pause: \(error)"}
    }
    func update() {
        live?.advancing=follow.state == .on && !paused && !cancelled && !finished
        live?.controller?.liveAdvancing=live?.advancing ?? false
        if cancelled,live != nil {try? Data().write(to:output.appendingPathComponent("live/cancel"))}
        if follow.state == .on {do {try live?.update()}catch {follow.state = .off;status.stringValue="Live inspection stopped: \(error)";fputs("Live inspection: \(error)\n",stderr)}}
        if !cancelled,let data=try? Data(contentsOf:output.appendingPathComponent("live/status.json")),
           let state=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],state["state"] as? String == "paused" {
            status.stringValue="Paused after operation \(state["completed_operations"] as? Int ?? 0). Live history is safe to inspect."
            return
        }
        guard !cancelled,let p=Self.progressRecord(output.appendingPathComponent("progress.jsonl")),p["version"] as? Int==1,let phase=p["phase"] as? String,let done=p["completed_operations"] as? Int,let total=p["total_operations"] as? Int,done>=0,done<=total else {return}
        if phase=="cutting" {
            progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=Double(max(1,total));progress.doubleValue=Double(done)
            status.stringValue="Cutting: \(done) / \(total) operations\n"+String((p["operation"] as? String ?? "").prefix(200))
        } else {
            progress.isIndeterminate=true;progress.startAnimation(nil)
            status.stringValue=phase=="finalizing" ? "Writing result and inspection data…":phase=="complete" ? "Loading result…":"Preparing stock, target and fixtures…"
        }
    }
    func cancel() {
        guard !finished else {return}
        cancelled=true;button.isEnabled=false;status.stringValue="Cancelling calculation…"
        if live != nil {
            // Cooperative cancellation at an operation boundary; no arbitrary
            // kill timeout for a potentially long individual cut.
            try? Data().write(to:output.appendingPathComponent("live/cancel"))
            status.stringValue="Cancelling after the current operation…"
            return
        }
        if process.isRunning {process.terminate()}
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
            guard let s=self,!s.finished,s.process.isRunning else {return}
            kill(s.process.processIdentifier,SIGKILL)
        }
    }
    @objc func cancelOrClose() {if finished {window.close()}else{cancel()}}
    @objc func openLogFile() {NSWorkspace.shared.open(output.appendingPathComponent("simulation.log"))}
    func windowShouldClose(_ sender:NSWindow)->Bool {if finished{return true};cancel();return false}
    func complete() {
        guard !finished else {return};finished=true;live?.advancing=false;live?.controller?.liveAdvancing=false;pause.isEnabled=false;timer?.invalidate();try? log?.close();progress.stopAnimation(nil)
        if quitRequested {NSApp.reply(toApplicationShouldTerminate:true);return}
        if cancelled {
            status.stringValue="Calculation cancelled. Logs and the last live window were retained; no final result was loaded."
            button.title="Close";button.isEnabled=true
            if automated {fputs("Simulation cancelled\n",stderr);exit(2)}
            return
        }
        let record=Self.progressRecord(output.appendingPathComponent("progress.jsonl"))
        let manifest=output.appendingPathComponent("voxel-animation.json")
        guard process.terminationReason == .exit,process.terminationStatus==0,record?["phase"] as? String=="complete",FileManager.default.fileExists(atPath:manifest.path) else {
            let tail=String(decoding:Self.tail(output.appendingPathComponent("simulation.log")).suffix(4000),as:UTF8.self)
            status.stringValue="Calculation failed (exit \(process.terminationStatus)). No result was loaded.\n\(tail)";button.title="Close";button.isEnabled=true
            fputs("\(status.stringValue)\n",stderr)
            if automated {exit(1)}
            return
        }
        onSuccess?(manifest)
        live?.close()
        // Create the result window before closing the last progress window.
        window.close()
    }
}


/// A lease remains held for the entire lifetime of a lazily read history window.
/// Read pointer -> lock -> verify sequence: slot rotation cannot race loading.
final class LiveLease {
    let fd:Int32
    init?(_ url:URL) {
        fd=Darwin.open(url.path,O_RDONLY)
        guard fd>=0 else {return nil}
        if flock(fd,LOCK_SH|LOCK_NB) != 0 {Darwin.close(fd);return nil}
    }
    deinit {flock(fd,LOCK_UN);Darwin.close(fd)}
}
final class LiveInspection {
    let output:URL
    var lease:LiveLease?
    var window:NSWindow?
    var controller:VoxelController?
    var sequence=0
    var lastLoad=Date.distantPast
    var savedSnapshot=false
    var verifiedHistory=false
    var loading=false
    var closed=false
    var following=true
    var advancing=true
    var loadError:Error?
    let loader=DispatchQueue(label:"menkh.live-window-loader",qos:.userInitiated)
    init(output:URL) {self.output=output}
    func close() {
        closed=true
        controller?.timer?.invalidate();controller?.metal.isPaused=true
        window?.close();window=nil;controller=nil;lease=nil
    }
    func update() throws {
        if let error=loadError {loadError=nil;throw error}
        guard !closed,!loading,Date().timeIntervalSince(lastLoad)>=0.15 else {return}
        let root=output.appendingPathComponent("live")
        guard let data=try? Data(contentsOf:root.appendingPathComponent("latest.json")),
              let info=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              info["version"] as? Int == 1,let next=info["sequence"] as? Int,next>sequence,
              let slot=info["slot"] as? Int,(0..<3).contains(slot),
              let first=info["first_operation"] as? Int,let completed=info["completed_operations"] as? Int,
              let held=LiveLease(root.appendingPathComponent("slot-\(slot).lock")) else {return}
        let file=root.appendingPathComponent("slot-\(slot)/voxel-animation.json")
        let meta=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]
        guard meta?["live_sequence"] as? Int == next else {return}
        let start=CFAbsoluteTimeGetCurrent()
        let previous=controller?.renderer
        loading=true
        // One preparation at a time. The old drawable and lease stay alive while
        // files, provenance and immutable assets are validated off the UI thread.
        loader.async { [weak self] in
            let result=Result {try VoxelRenderer(file,sharing:previous)}
            let loaded=CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async { [weak self] in
                guard let self else {return}
                defer {self.loading=false}
                guard !self.closed,self.following else {return}
                do {try self.present(try result.get(),held:held,info:info,next:next,first:first,completed:completed,start:start,loaded:loaded)}
                catch {self.loadError=error}
            }
        }
    }
    func present(_ renderer:VoxelRenderer,held:LiveLease,info:[String:Any],next:Int,first:Int,completed:Int,start:Double,loaded:Double) throws {
        let seekStart=CFAbsoluteTimeGetCurrent()
        let previousDraws=controller?.renderer.drawCount ?? 0
        let previousGap=controller?.renderer.maximumDrawGapMS ?? 0
        if controller == nil {renderer.provenanceMode=CommandLine.arguments.contains("--color-operation") ? 1:CommandLine.arguments.contains("--color-tool") ? 2:0;renderer.compareTarget=CommandLine.arguments.contains("--compare-target")}
        let previousGlobal=controller.map {$0.renderer.operationOffset+$0.renderer.frame} ?? completed
        let localStart=max(0,min(renderer.history.frames.count,previousGlobal-first))
        try renderer.seek(localStart)
        let sought=CFAbsoluteTimeGetCurrent()
        if let old=controller?.renderer {
            renderer.lastDrawTime=old.lastDrawTime
            renderer.yaw=old.yaw;renderer.elevation=old.elevation;renderer.roll=old.roll
            renderer.target=old.target;renderer.distance=old.distance
            renderer.sectionAxis=old.sectionAxis;renderer.sectionFraction=old.sectionFraction
            renderer.smoothLighting=old.smoothLighting;renderer.darkBackground=old.darkBackground
            renderer.showStock=old.showStock;renderer.showHolder=old.showHolder
            renderer.provenanceMode=old.provenanceMode;renderer.compareTarget=old.compareTarget;renderer.showFixtures=old.showFixtures
        }
        let firstWindow = window == nil
        if firstWindow {
            let nextController=VoxelController(renderer);nextController.playing=false
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            w.isReleasedWhenClosed=false;w.center();window=w
            w.contentViewController=nextController;controller=nextController
            w.makeKeyAndOrderFront(nil)
        } else {
            let view=controller!.metal
            try controller!.replaceLiveRenderer(renderer,animate:true)
            precondition(controller!.metal === view && window!.contentViewController === controller!)
        }
        controller!.liveAdvancing=advancing
        window!.title="Menkh — LIVE · retained operations \(first)…\(completed) · uncheck Follow latest to seek"
        lease=held;sequence=next;lastLoad=Date()
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let record:[String:Any]=["process_peak_rss_bytes":usage.ru_maxrss,"sequence":next,"first_operation":first,"completed_operations":completed,"load_upload_ms":(loaded-start)*1000,"seek_ms":(sought-seekStart)*1000,"gpu_material_bytes":renderer.blocks.length+renderer.pool.length,"gpu_provenance_bytes":renderer.provenanceBuffer?.length ?? 0,"gpu_asset_bytes":[renderer.targetBlocks,renderer.targetPool,renderer.fixtureBlocks,renderer.fixturePool].compactMap{$0}.reduce(0){$0+$1.length},"publication":info,"drawable_width":controller!.metal.drawableSize.width,"drawable_height":controller!.metal.drawableSize.height,"persistent_view":!firstWindow,"previous_window_draws":previousDraws,"previous_window_max_draw_gap_ms":previousGap,"displayed_operation":renderer.operationOffset+renderer.frame]
        let line=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])+Data([10])
        let log=output.appendingPathComponent("live-viewer.jsonl")
        if !FileManager.default.fileExists(atPath:log.path) {try Data().write(to:log)}
        let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()}
        try handle.seekToEnd();try handle.write(contentsOf:line)
        // Reproducible evidence captured while the producer is still running.
        if !verifiedHistory,renderer.history.frames.count>0,let path=try JobRunner.argument("--live-verify-history") {
            try renderer.verifyHistory(to:URL(fileURLWithPath:path));verifiedHistory=true
        }
        let snapshotOperation=Int(try JobRunner.argument("--live-snapshot-operation") ?? "1") ?? 1
        if !savedSnapshot,completed>=snapshotOperation,let path=try JobRunner.argument("--live-snapshot") {
            controller?.livePlaybackEnd=nil;try renderer.seek(renderer.history.frames.count)
            let image=try renderer.image()
            guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw MeshError.imageEncoding}
            try png.write(to:URL(fileURLWithPath:path));savedSnapshot=true
        }
    }
}
