import AppKit
import MetalKit
import simd
import AVFoundation

struct VoxelStep:Decodable {let file:String;let stage:String;let occupied:UInt64;let changed_blocks:Int;let delta_bytes:Int;let tool:[Float]}
struct VoxelHistory:Decodable {
    let format:String;let grid:[Int];let block_grid:[Int];let voxel_mm:Float
    let initial_occupied:UInt64;let final_occupied:UInt64;let pool_slots:Int
    let stock_min:[Float];let stock_max:[Float];let frames:[VoxelStep]
}
struct VoxelUniforms {
    var eye:SIMD4<Float>;var forward:SIMD4<Float>;var right:SIMD4<Float>;var up:SIMD4<Float>
    var low:SIMD4<Float>;var high:SIMD4<Float>;var settings:SIMD4<Float>;var grid:SIMD4<UInt32>
}
final class VoxelRenderer:NSObject,MTKViewDelegate {
    let history:VoxelHistory;let root:URL;let device:MTLDevice;let queue:MTLCommandQueue;let pipeline:MTLComputePipelineState
    let blocks:MTLBuffer;let pool:MTLBuffer
    var frame=0;var yaw:Float = -0.8;var elevation:Float = 0.27;var distance:Float = 72
    var target=SIMD3<Float>(30,30,30);var roll:Float = .pi/2
    var smoothLighting=false;var darkBackground=false
    var lastCommand:MTLCommandBuffer?
    var lastGPUms:Double=0
    init(_ file:URL) throws {
        root=file.deletingLastPathComponent();let decoded=try JSONDecoder().decode(VoxelHistory.self,from:Data(contentsOf:file));history=decoded
        let n=decoded.grid.first ?? 0
        guard history.format=="menkh-voxel-history-v1",history.grid.count==3,history.block_grid.count==3,history.stock_min.count==3,history.stock_max.count==3,history.grid.allSatisfy({$0>=32 && $0<=4096 && $0%8==0}),history.grid.allSatisfy({$0==n}),history.block_grid.allSatisfy({$0==n/8}),history.pool_slots>=0,history.pool_slots<history.block_grid.reduce(1,*),history.voxel_mm.isFinite,history.voxel_mm>0 else {throw MeshError.invalidOBJ("Invalid voxel history")}
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw MeshError.noMetal};self.device=device;self.queue=queue
        let shader=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Voxel.metal")
        let options=MTLCompileOptions();options.mathMode = .safe
        let library=try device.makeLibrary(source:String(contentsOf:shader,encoding:.utf8),options:options)
        guard let function=library.makeFunction(name:"voxelImage") else {throw MeshError.noMetal};pipeline=try device.makeComputePipelineState(function:function)
        let size=history.block_grid.reduce(1,*)*4
        guard let blocks=device.makeBuffer(length:size,options:.storageModeShared),let pool=device.makeBuffer(length:max(64,history.pool_slots*64),options:.storageModeShared) else {throw MeshError.noMetal}
        self.blocks=blocks;self.pool=pool
        let initial=try Data(contentsOf:root.appendingPathComponent("initial.blocks"),options:.mappedIfSafe)
        guard initial.count==size else {throw MeshError.invalidOBJ("Invalid initial block file")};initial.copyBytes(to:blocks.contents().assumingMemoryBound(to:UInt8.self),count:initial.count)
        let bits=try Data(contentsOf:root.appendingPathComponent("initial.pool"),options:.mappedIfSafe)
        guard bits.count<=pool.length && bits.count%64==0 else {throw MeshError.invalidOBJ("Invalid bit pool")};bits.copyBytes(to:pool.contents().assumingMemoryBound(to:UInt8.self),count:bits.count)
        super.init()
    }
    func apply(_ index:Int,forward:Bool) throws {
        let step=history.frames[index]
        guard URL(fileURLWithPath:step.file).lastPathComponent==step.file else {throw MeshError.invalidOBJ("Invalid change path")}
        let bytes=try Data(contentsOf:root.appendingPathComponent(step.file),options:.mappedIfSafe)
        guard bytes.count==step.delta_bytes else {throw MeshError.invalidOBJ("Invalid delta size")}
        try bytes.withUnsafeBytes { (data:UnsafeRawBufferPointer) in
            var cursor=0;var records=0
            // First validate everything before changing a single descriptor.
            for pass in 0..<2 {
                cursor=0;records=0
                while cursor<data.count {
                    guard cursor+12<=data.count else {throw MeshError.invalidOBJ("Truncated delta header")}
                    let id=Int(UInt32(littleEndian:data.loadUnaligned(fromByteOffset:cursor,as:UInt32.self)))
                    let before=UInt32(littleEndian:data.loadUnaligned(fromByteOffset:cursor+4,as:UInt32.self))
                    let after=UInt32(littleEndian:data.loadUnaligned(fromByteOffset:cursor+8,as:UInt32.self));cursor+=12
                    guard id<blocks.length/4 else {throw MeshError.invalidOBJ("Block out of range")}
                    let beforeOffset=cursor;if before<0xfffffffe {cursor+=64;guard Int(before)<history.pool_slots else {throw MeshError.invalidOBJ("Pool index out of range")}}
                    let afterOffset=cursor;if after<0xfffffffe {cursor+=64;guard Int(after)<history.pool_slots else {throw MeshError.invalidOBJ("Pool index out of range")}}
                    guard cursor<=data.count else {throw MeshError.invalidOBJ("Truncated bit field")}
                    if pass==1 {
                        let d=forward ? after:before
                        if d<0xfffffffe {pool.contents().advanced(by:Int(d)*64).copyMemory(from:data.baseAddress!.advanced(by:forward ? afterOffset:beforeOffset),byteCount:64)}
                        blocks.contents().assumingMemoryBound(to:UInt32.self)[id]=d
                    }
                    records+=1
                }
                guard records==step.changed_blocks else {throw MeshError.invalidOBJ("Delta count mismatch")}
            }
        }
    }
    func seek(_ value:Int) throws {
        guard value>=0 && value<=history.frames.count else {throw MeshError.invalidOBJ("Frame out of range")}
        lastCommand?.waitUntilCompleted()
        while frame<value {try apply(frame,forward:true);frame+=1}
        while frame>value {try apply(frame-1,forward:false);frame-=1}
    }
    func uniforms(width:Int,height:Int)->VoxelUniforms {
        let offset=distance*SIMD3<Float>(cos(elevation)*cos(yaw),cos(elevation)*sin(yaw),sin(elevation))
        let eye=target+offset;let forward=simd_normalize(target-eye)
        let right0=simd_normalize(simd_cross(forward,SIMD3<Float>(0,0,1)));let up0=simd_cross(right0,forward)
        let right=right0*cos(roll)+up0*sin(roll);let up=up0*cos(roll)-right0*sin(roll)
        let h=history.voxel_mm
        let low=SIMD3<Float>(history.stock_min[0],history.stock_min[1],history.stock_min[2])/h-SIMD3<Float>(repeating:1)
        let high=SIMD3<Float>(history.stock_max[0],history.stock_max[1],history.stock_max[2])/h+SIMD3<Float>(repeating:1)
        return VoxelUniforms(eye:SIMD4(eye/h,0),forward:SIMD4(forward,0),right:SIMD4(right,0),up:SIMD4(up,0),low:SIMD4(simd_max(low,SIMD3(repeating:0)),0),high:SIMD4(simd_min(high,SIMD3(repeating:Float(history.grid[0]))),0),settings:SIMD4(h,Float(width),Float(height),tan(Float.pi/8)),grid:SIMD4(UInt32(history.block_grid[0]),UInt32(history.grid[0]),darkBackground ? 1:0,smoothLighting ? 1:0))
    }
    func encode(_ texture:MTLTexture)->MTLCommandBuffer? {
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else {return nil}
        var u=uniforms(width:texture.width,height:texture.height)
        encoder.setComputePipelineState(pipeline);encoder.setTexture(texture,index:0);encoder.setBuffer(blocks,offset:0,index:0);encoder.setBuffer(pool,offset:0,index:1);encoder.setBytes(&u,length:MemoryLayout<VoxelUniforms>.stride,index:2)
        encoder.dispatchThreads(MTLSize(width:texture.width,height:texture.height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1));encoder.endEncoding()
        return command
    }
    func draw(in view:MTKView) {
        guard let drawable=view.currentDrawable,let command=encode(drawable.texture) else {return}
        command.present(drawable);command.commit();lastCommand=command
        // Single in-flight image guarantees CPU delta uploads cannot race GPU reads.
        command.waitUntilCompleted();lastGPUms=(command.gpuEndTime-command.gpuStartTime)*1000
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    func image(width:Int=1280,height:Int=900) throws -> NSImage {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false);descriptor.usage=[.shaderWrite,.shaderRead];descriptor.storageMode = .shared
        guard let texture=device.makeTexture(descriptor:descriptor),let command=encode(texture) else {throw MeshError.noMetal}
        command.commit();command.waitUntilCompleted();guard command.status == .completed else {throw command.error ?? MeshError.imageEncoding}
        lastGPUms=(command.gpuEndTime-command.gpuStartTime)*1000
        let bytes=UnsafeMutableRawPointer.allocate(byteCount:width*height*4,alignment:16);defer {bytes.deallocate()}
        texture.getBytes(bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),let destination=bitmap.bitmapData else {throw MeshError.imageEncoding}
        destination.update(from:bytes.assumingMemoryBound(to:UInt8.self),count:width*height*4)
        let image=NSImage(size:NSSize(width:width,height:height));image.addRepresentation(bitmap);return image
    }
    var label:String {
        let occupied=frame==0 ? history.initial_occupied:history.frames[frame-1].occupied
        let stage=frame==0 ? "Zylinder":frame==history.frames.count ? "Fertig":history.frames[frame-1].stage
        return "\(stage) · \(frame)/\(history.frames.count) · \(history.grid[0])³ · \(String(format:"%.3f",history.voxel_mm*1000)) µm · \(occupied.formatted()) belegt · GPU \(String(format:"%.1f",lastGPUms)) ms"
    }
}
final class VoxelMetalView:MTKView {
    var renderer:VoxelRenderer?
    override var acceptsFirstResponder:Bool {true}
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount==2,let r=renderer {
            let p=convert(event.locationInWindow,from:nil)
            r.focus(x:Float(p.x/bounds.width),y:Float(1-p.y/bounds.height),aspect:Float(bounds.width/bounds.height))
        }
    }
    override func mouseDragged(with event:NSEvent) {
        guard let r=renderer else {return}
        if event.modifierFlags.contains(.shift) {
            let u=r.uniforms(width:1,height:1);let right=SIMD3(u.right.x,u.right.y,u.right.z);let up=SIMD3(u.up.x,u.up.y,u.up.z)
            r.target+=(-Float(event.deltaX)*right+Float(event.deltaY)*up)*r.distance*0.0015
        } else {r.yaw-=Float(event.deltaX)*0.008;r.elevation=clamp(r.elevation+Float(event.deltaY)*0.008,-1.5,1.5)}
    }
    override func scrollWheel(with event:NSEvent) {guard let r=renderer else {return};r.distance=clamp(r.distance*exp(Float(event.scrollingDeltaY)*0.015),0.05,300)}
    func clamp(_ x:Float,_ low:Float,_ high:Float)->Float {min(high,max(low,x))}
}
final class VoxelController:NSViewController {
    let renderer:VoxelRenderer;let metal:VoxelMetalView
    let status=NSTextField(labelWithString:"");let slider=NSSlider(value:0,minValue:0,maxValue:224,target:nil,action:nil)
    let play=NSButton(title:"Pause",target:nil,action:nil);var playing=true;var timer:Timer?
    init(_ r:VoxelRenderer) {renderer=r;metal=VoxelMetalView(frame:.zero,device:r.device);super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError("No storyboard")}
    override func loadView() {
        view=NSView(frame:NSRect(x:0,y:0,width:1280,height:900))
        metal.frame=view.bounds;metal.autoresizingMask=[.width,.height];metal.framebufferOnly=false;metal.colorPixelFormat = .bgra8Unorm;metal.delegate=renderer;metal.renderer=renderer;metal.preferredFramesPerSecond=60
        view.addSubview(metal)
        let title=NSTextField(labelWithString:"MENKH / VOXEL CUTTING");title.font = .systemFont(ofSize:19,weight:.bold);title.textColor = .white
        let help=NSTextField(labelWithString:"Ziehen: drehen · Scrollen: Detailzoom · Doppelklick: Oberfläche fokussieren · Shift + Ziehen: verschieben");help.textColor = .white
        let reset=NSButton(title:"Kamera zurücksetzen",target:self,action:#selector(resetCamera))
        let lighting=NSButton(checkboxWithTitle:"Normalen mitteln (nur Beleuchtung)",target:self,action:#selector(lighting(_:)))
        lighting.state=renderer.smoothLighting ? .on : .off
        let background=NSButton(checkboxWithTitle:"Dunkler Hintergrund",target:self,action:#selector(background(_:)))
        let restart=NSButton(title:"Neustart",target:self,action:#selector(restart))
        play.target=self;play.action=#selector(toggle);slider.target=self;slider.action=#selector(scrub);slider.isContinuous=true;slider.maxValue=Double(renderer.history.frames.count)
        status.textColor = .white;status.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
        let buttons=NSStackView(views:[play,restart,reset,lighting,background]);buttons.spacing=12
        let top=NSStackView(views:[title,help]);top.orientation = .vertical;top.alignment = .leading;top.spacing=8;top.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(top)
        let bottom=NSStackView(views:[status,slider,buttons]);bottom.orientation = .vertical;bottom.alignment = .leading;bottom.spacing=10;bottom.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(bottom)
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),top.topAnchor.constraint(equalTo:view.topAnchor,constant:20),bottom.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),bottom.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-22),bottom.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-22),slider.widthAnchor.constraint(equalTo:bottom.widthAnchor)])
        refresh();timer=Timer.scheduledTimer(withTimeInterval:1/12,repeats:true) { [weak self] _ in self?.tick() }
    }
    func refresh() {status.stringValue=renderer.label;slider.doubleValue=Double(renderer.frame);play.title=playing ? "Pause":"Abspielen"}
    func seek(_ n:Int) {do {try renderer.seek(n);refresh()}catch{playing=false;status.stringValue="Fehler: \(error)"}}
    func tick() {if playing {if renderer.frame<renderer.history.frames.count {seek(renderer.frame+1)}else{playing=false}};refresh()}
    @objc func toggle() {playing.toggle();refresh()}
    @objc func restart() {playing=true;seek(0)}
    @objc func scrub() {playing=false;seek(Int(slider.doubleValue.rounded()))}
    @objc func resetCamera() {renderer.yaw = -0.8;renderer.elevation=0.27;renderer.distance=72;renderer.target=SIMD3(30,30,30)}
    @objc func lighting(_ b:NSButton) {renderer.smoothLighting=b.state == .on}
    @objc func background(_ b:NSButton) {renderer.darkBackground=b.state == .on}
    deinit {timer?.invalidate()}
}
extension Delegate {
    func openVoxels(_ file:URL) throws {
        let renderer=try VoxelRenderer(file);let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--frame"),i+1<args.count,let frame=Int(args[i+1]) {try renderer.seek(frame)}
        if args.contains("--smooth-lighting") {renderer.smoothLighting=true}
        if let i=args.firstIndex(of:"--distance"),i+1<args.count,let distance=Float(args[i+1]),distance.isFinite,distance>0 {renderer.distance=distance}
        if let i=args.firstIndex(of:"--target-z"),i+1<args.count,let z=Float(args[i+1]),z.isFinite {renderer.target.z=z}
        if let i=args.firstIndex(of:"--movie"),i+1<args.count {try renderer.movie(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return}
        if let i=args.firstIndex(of:"--verify-history"),i+1<args.count {try renderer.verifyHistory(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return}
        if let i=args.firstIndex(of:"--render-bench"),i+1<args.count {
            var samples=[Double]();for j in 0..<13 {_ = try renderer.image();if j>=3 {samples.append(renderer.lastGPUms)}};samples.sort()
            let record:[String:Any] = ["grid":renderer.history.grid,"frame":renderer.frame,"width":1280,"height":900,"samples":10,"warmups":3,"gpu_ms_min":samples.first!,"gpu_ms_median":(samples[4]+samples[5])/2,"gpu_ms_max":samples.last!,"averaged_normals":renderer.smoothLighting,"samples_per_pixel":4,"note":"GPU command duration only, offscreen static view; not interactive FPS"]
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return
        }
        if let i=args.firstIndex(of:"--snapshot"),i+1<args.count {
            let image=try renderer.image();guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw MeshError.imageEncoding}
            try png.write(to:URL(fileURLWithPath:args[i+1]));print(renderer.label);NSApp.terminate(nil);return
        }
        let controller=VoxelController(renderer)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="menkh — \(renderer.history.grid[0])³ Voxelabtrag";window.contentViewController=controller;window.center();window.makeKeyAndOrderFront(nil);self.window=window;NSApp.activate(ignoringOtherApps:true)
    }
}

extension VoxelRenderer {
    func movie(to url:URL) throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let width=1280;let height=900
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:8_000_000]])
        input.expectsMediaDataInRealTime=false
        let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(input);guard writer.startWriting() else {throw writer.error ?? MeshError.imageEncoding};writer.startSession(atSourceTime:.zero)
        let order=Array(repeating:0,count:12)+Array(0...history.frames.count)+Array(repeating:history.frames.count,count:72)
        for (i,f) in order.enumerated() {
            try autoreleasepool {
                try seek(f)
                if i>12+history.frames.count {
                    let t=Float(i-12-history.frames.count)/72
                    distance=72-48*t;target.z=30+15*t;yaw = -0.8+0.8*t
                }
                let image=try image(width:width,height:height)
                image.lockFocus()
                let title:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:22,weight:.bold),.foregroundColor:NSColor.white]
                ("MENKH / \(history.grid[0]) × \(history.grid[1]) × \(history.grid[2]) VOXEL" as NSString).draw(at:NSPoint(x:24,y:height-44),withAttributes:title)
                let detail:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:14,weight:.medium),.foregroundColor:NSColor.white]
                ("\(frame==0 ? "Zylinder":history.frames[frame-1].stage) · Schnitt \(frame)/\(history.frames.count) · \(String(format:"%.3f",history.voxel_mm*1000)) µm · CPU-Abtrag / Metal-Darstellung" as NSString).draw(at:NSPoint(x:24,y:24),withAttributes:detail)
                image.unlockFocus()
                var rect=CGRect(x:0,y:0,width:width,height:height)
                guard let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil),let buffers=adapter.pixelBufferPool else {throw MeshError.imageEncoding}
                var maybe:CVPixelBuffer?;guard CVPixelBufferPoolCreatePixelBuffer(nil,buffers,&maybe)==kCVReturnSuccess,let pixel=maybe else {throw MeshError.imageEncoding}
                CVPixelBufferLockBaseAddress(pixel,[]);defer {CVPixelBufferUnlockBaseAddress(pixel,[])}
                guard let context=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else {throw MeshError.imageEncoding}
                context.draw(cg,in:rect)
                let deadline=Date().addingTimeInterval(20)
                while !input.isReadyForMoreMediaData {if writer.status == .failed || Date()>deadline {throw writer.error ?? MeshError.imageEncoding};Thread.sleep(forTimeInterval:0.002)}
                guard adapter.append(pixel,withPresentationTime:CMTime(value:Int64(i),timescale:12)) else {throw writer.error ?? MeshError.imageEncoding}
            }
        }
        input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting {done.signal()};done.wait()
        guard writer.status == .completed else {throw writer.error ?? MeshError.imageEncoding}
        print("4096-grid video: \(order.count) frames, \(url.path)")
    }
    func occupiedCount()->UInt64 {
        let descriptors=blocks.contents().assumingMemoryBound(to:UInt32.self)
        let words=pool.contents().assumingMemoryBound(to:UInt64.self)
        var count:UInt64=0
        for i in 0..<blocks.length/4 {
            let d=descriptors[i]
            if d==0xfffffffe {count+=512}
            else if d<0xfffffffe {for z in 0..<8 {count+=UInt64(words[Int(d)*8+z].nonzeroBitCount)}}
        }
        return count
    }
    func verifyHistory(to url:URL) throws {
        try seek(0);let initial=occupiedCount();guard initial==history.initial_occupied else {throw MeshError.invalidOBJ("Initial count mismatch")}
        try seek(history.frames.count);let final=occupiedCount();guard final==history.final_occupied else {throw MeshError.invalidOBJ("Final count mismatch")}
        // Compare the entire reconstructed initial descriptor array and original pool bytes.
        try seek(0)
        let source=try Data(contentsOf:root.appendingPathComponent("initial.blocks"),options:.mappedIfSafe)
        let bits=try Data(contentsOf:root.appendingPathComponent("initial.pool"),options:.mappedIfSafe)
        let same=source.withUnsafeBytes {memcmp($0.baseAddress!,blocks.contents(),source.count)==0}
        let samePool=bits.withUnsafeBytes {memcmp($0.baseAddress!,pool.contents(),bits.count)==0}
        guard same && samePool else {throw MeshError.invalidOBJ("Backward history differs")}
        try seek(history.frames.count);guard occupiedCount()==final else {throw MeshError.invalidOBJ("Replay differs")}
        let record:[String:Any]=["grid":history.grid,"initial_occupied":initial,"final_occupied":final,"reverse_descriptors_byte_exact":same,"reverse_initial_pool_byte_exact":samePool,"forward_replay_validated":true]
        try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:url)
        print("Full-size forward/backward/forward history verified")
    }
}

extension VoxelRenderer {
    /// Focus the camera on a picked, actually occupied voxel; enables inspection down to voxel scale.
    func focus(x:Float,y:Float,aspect:Float) {
        let u=uniforms(width:Int(aspect*1000),height:1000)
        let eye=SIMD3(u.eye.x,u.eye.y,u.eye.z)
        let forward=SIMD3(u.forward.x,u.forward.y,u.forward.z)
        let right=SIMD3(u.right.x,u.right.y,u.right.z);let up=SIMD3(u.up.x,u.up.y,u.up.z)
        let ray=simd_normalize(forward+u.settings.w*((x*2-1)*aspect*right+(1-y*2)*up))
        var inverse=SIMD3<Float>();for j in 0..<3 {inverse[j]=1/(abs(ray[j])<1e-15 ? 1e-15:ray[j])}
        let low=SIMD3(u.low.x,u.low.y,u.low.z);let high=SIMD3(u.high.x,u.high.y,u.high.z)
        let near=simd_min((low-eye)*inverse,(high-eye)*inverse);let far=simd_max((low-eye)*inverse,(high-eye)*inverse)
        var t=max(0,max(near.x,max(near.y,near.z)));let end=min(far.x,min(far.y,far.z));if t>end {return}
        let n=history.grid[0];let nb=history.block_grid[0]
        let descriptors=blocks.contents().assumingMemoryBound(to:UInt32.self);let words=pool.contents().assumingMemoryBound(to:UInt64.self)
        for _ in 0..<3*n+8 {
            let position=eye+ray*(t+0.001);let p=[Int(floor(position.x)),Int(floor(position.y)),Int(floor(position.z))]
            if p.contains(where:{$0<0 || $0>=n}) {return}
            let d=descriptors[((p[2]/8)*nb+p[1]/8)*nb+p[0]/8]
            let occupied=d==0xfffffffe || (d<0xfffffffe && (words[Int(d)*8+p[2]%8] & (UInt64(1)<<UInt64(p[1]%8*8+p[0]%8))) != 0)
            if occupied {
                let hit=(eye+ray*t)*history.voxel_mm;let oldEye=eye*history.voxel_mm
                let offset=oldEye-hit;let length=simd_length(offset)
                if length>0.01 {target=hit;distance=length;yaw=atan2(offset.y,offset.x);elevation=asin(offset.z/length)}
                return
            }
            let step=d==0xffffffff ? 8:1
            var next=SIMD3<Float>();for j in 0..<3 {let edge=Float((p[j]/step)*step+(ray[j]>0 ? step:0));next[j]=(edge-eye[j])*inverse[j]}
            t=max(min(next.x,min(next.y,next.z)),t+0.001);if t>end {return}
        }
    }
}
