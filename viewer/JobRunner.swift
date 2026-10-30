import AppKit
import Foundation
import Darwin

/// Runs the existing engine out of process. Only a successful, complete result
/// is published to the viewer; cancelled/failed directories are retained as logs.
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
        process.standardOutput=log;process.standardError=log;process.standardInput=FileHandle.nullDevice
        window.isReleasedWhenClosed=false
        window.title="Menkh — calculating \(job.lastPathComponent)";window.delegate=self
        status.maximumNumberOfLines=5
        let location=NSTextField(wrappingLabelWithString:"Result and log: \(output.path)");location.isSelectable=true;location.maximumNumberOfLines=3
        progress.isIndeterminate=true;progress.style = .bar;progress.startAnimation(nil)
        button.target=self;button.action=#selector(cancelOrClose)
        let openLog=NSButton(title:"Open log",target:self,action:#selector(openLogFile))
        let buttons=NSStackView(views:[button,openLog])
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
    func update() {
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
        guard !finished else {return};finished=true;timer?.invalidate();try? log?.close();progress.stopAnimation(nil)
        if quitRequested {NSApp.reply(toApplicationShouldTerminate:true);return}
        if cancelled {
            status.stringValue="Calculation cancelled. Partial files and logs were retained; no result was loaded."
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
        // Create the result window before closing the last progress window.
        window.close()
    }
}
