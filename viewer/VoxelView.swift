import AppKit
import MetalKit
import simd
import AVFoundation

struct NoncuttingPart:Decodable {let radius:Float;let length:Float;let offset:Float}
struct CutterGeometry:Decodable {let kind:String;let radius:Float;let length:Float}
struct VoxelStep:Decodable {let cutter:CutterGeometry?;let axis:[Float]?;let shank:NoncuttingPart?;let holder:NoncuttingPart?;let file:String;let stage:String;let occupied:UInt64;let changed_blocks:Int;let delta_bytes:Int;let tool:[Float]}
struct VoxelHistory:Decodable {
    let format:String;let grid:[Int];let block_grid:[Int];let voxel_mm:Float
    let origin_mm:[Float]?;let motion_tolerance_mm:Float?
    let initial_occupied:UInt64;let final_occupied:UInt64;let pool_slots:Int
    let stock_min:[Float];let stock_max:[Float];let frames:[VoxelStep]
}
struct VoxelUniforms {
    var eye:SIMD4<Float>;var forward:SIMD4<Float>;var right:SIMD4<Float>;var up:SIMD4<Float>
    var low:SIMD4<Float>;var high:SIMD4<Float>;var settings:SIMD4<Float>;var grid:SIMD4<UInt32>
    var dimensions:SIMD4<UInt32>;var blockDimensions:SIMD4<UInt32>
    var shank:SIMD4<Float>;var shankAxis:SIMD4<Float>;var holder:SIMD4<Float>;var holderAxis:SIMD4<Float>
    var cutter:SIMD4<Float>;var cutterAxis:SIMD4<Float>
    var provenance:SIMD4<UInt32>
}
final class VoxelRenderer:NSObject,MTKViewDelegate {
    let history:VoxelHistory;let root:URL;let device:MTLDevice;let queue:MTLCommandQueue;let pipeline:MTLComputePipelineState
    let blocks:MTLBuffer;let pool:MTLBuffer
    var provenanceAllFrames=false
    var provenanceAvailableAtFrame:Bool {provenanceAllFrames || frame==history.frames.count}
    var provenanceBuffer:MTLBuffer?;var provenanceCount:UInt32=0;var provenanceMode:UInt32=0
    var targetBlocks:MTLBuffer?;var targetPool:MTLBuffer?
    var fixtureBlocks:MTLBuffer?;var fixturePool:MTLBuffer?
    var showFixtures=true;var showHolder=true;var showStock=true
    var compareTarget=false;var sectionFraction:Float=1;var sectionAxis=2
    var picked:String=""
    var origin:SIMD3<Float> {let o=history.origin_mm ?? [0,0,0];return SIMD3(o[0],o[1],o[2])}
    var frame=0;var yaw:Float = -0.8;var elevation:Float = 0.27;var distance:Float = 72
    var target=SIMD3<Float>(30,30,30);var roll:Float = .pi/2
    var smoothLighting=false;var darkBackground=false
    var lastCommand:MTLCommandBuffer?
    var lastGPUms:Double=0
    init(_ file:URL) throws {
        root=file.deletingLastPathComponent();let decoded=try JSONDecoder().decode(VoxelHistory.self,from:Data(contentsOf:file));history=decoded

        guard history.format=="menkh-voxel-history-v1",history.grid.count==3,history.block_grid.count==3,history.stock_min.count==3,history.stock_max.count==3,history.grid.allSatisfy({$0>=1 && $0<=4096}),zip(history.grid,history.block_grid).allSatisfy({($0.0+7)/8==$0.1}),history.pool_slots>=0,history.pool_slots<=history.block_grid.reduce(1,*),history.voxel_mm.isFinite,history.voxel_mm>0 else {throw MeshError.invalidOBJ("Invalid voxel history")}
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
        guard (history.origin_mm ?? [0,0,0]).count==3,(history.origin_mm ?? [0,0,0]).allSatisfy({$0.isFinite}),history.stock_min.allSatisfy({$0.isFinite}),history.stock_max.allSatisfy({$0.isFinite}) else {throw MeshError.invalidOBJ("Invalid scene bounds")}
        let descriptors=blocks.contents().assumingMemoryBound(to:UInt32.self)
        for i in 0..<size/4 {let d=descriptors[i];guard d>=0xfffffffe || Int(d)<bits.count/64 else {throw MeshError.invalidOBJ("Invalid initial descriptor")}}
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("target.blocks").path) {
            let tb=try Data(contentsOf:root.appendingPathComponent("target.blocks"));let tp=try Data(contentsOf:root.appendingPathComponent("target.pool"))
            guard tb.count==size,tp.count%64==0 else {throw MeshError.invalidOBJ("Invalid target buffers")}
            for i in 0..<size/4 {let d=tb.withUnsafeBytes {UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))};guard d>=0xfffffffe || Int(d)<tp.count/64 else {throw MeshError.invalidOBJ("Invalid target descriptor")}}
            targetBlocks=device.makeBuffer(length:size,options:.storageModeShared);targetPool=device.makeBuffer(length:max(64,tp.count),options:.storageModeShared)
            guard let t=targetBlocks,let p=targetPool else {throw MeshError.noMetal};tb.copyBytes(to:t.contents().assumingMemoryBound(to:UInt8.self),count:tb.count);tp.copyBytes(to:p.contents().assumingMemoryBound(to:UInt8.self),count:tp.count)
        }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("fixture.blocks").path) {
            let tb=try Data(contentsOf:root.appendingPathComponent("fixture.blocks"));let tp=try Data(contentsOf:root.appendingPathComponent("fixture.pool"))
            guard tb.count==size,tp.count%64==0 else {throw MeshError.invalidOBJ("Invalid fixture buffers")}
            for i in 0..<size/4 {let d=tb.withUnsafeBytes {UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))};guard d>=0xfffffffe || Int(d)<tp.count/64 else {throw MeshError.invalidOBJ("Invalid fixture descriptor")}}
            fixtureBlocks=device.makeBuffer(length:size,options:.storageModeShared);fixturePool=device.makeBuffer(length:max(64,tp.count),options:.storageModeShared)
            guard let t=fixtureBlocks,let p=fixturePool else {throw MeshError.noMetal};tb.copyBytes(to:t.contents().assumingMemoryBound(to:UInt8.self),count:tb.count);tp.copyBytes(to:p.contents().assumingMemoryBound(to:UInt8.self),count:tp.count)
        }
        try loadProvenance()
        resetView()

    }
    func apply(_ index:Int,forward:Bool) throws {
        let step=history.frames[index]
        guard URL(fileURLWithPath:step.file).lastPathComponent==step.file else {throw MeshError.invalidOBJ("Invalid change path")}
        let bytes=try Data(contentsOf:root.appendingPathComponent(step.file),options:.mappedIfSafe)
        guard bytes.count==step.delta_bytes else {throw MeshError.invalidOBJ("Invalid delta size")}
        try bytes.withUnsafeBytes { (data:UnsafeRawBufferPointer) in
            var cursor=0;var records=0;var previous = -1
            // First validate everything before changing a single descriptor.
            for pass in 0..<2 {
                cursor=0;records=0;previous = -1
                while cursor<data.count {
                    guard cursor+12<=data.count else {throw MeshError.invalidOBJ("Truncated delta header")}
                    let id=Int(UInt32(littleEndian:data.loadUnaligned(fromByteOffset:cursor,as:UInt32.self)))
                    let before=UInt32(littleEndian:data.loadUnaligned(fromByteOffset:cursor+4,as:UInt32.self))
                    let after=UInt32(littleEndian:data.loadUnaligned(fromByteOffset:cursor+8,as:UInt32.self));cursor+=12
                    guard id<blocks.length/4,id>previous else {throw MeshError.invalidOBJ("Block out of range")}
                    previous=id
                    let beforeOffset=cursor;if before<0xfffffffe {cursor+=64;guard Int(before)<history.pool_slots else {throw MeshError.invalidOBJ("Pool index out of range")}}
                    let afterOffset=cursor;if after<0xfffffffe {cursor+=64;guard Int(after)<history.pool_slots else {throw MeshError.invalidOBJ("Pool index out of range")}}
                    guard cursor<=data.count else {throw MeshError.invalidOBJ("Truncated bit field")}
                    if pass==0 {
                        let expected=forward ? before:after
                        guard blocks.contents().assumingMemoryBound(to:UInt32.self)[id]==expected else {throw MeshError.invalidOBJ("History state mismatch")}
                        if expected<0xfffffffe {let offset=forward ? beforeOffset:afterOffset;guard memcmp(pool.contents().advanced(by:Int(expected)*64),data.baseAddress!.advanced(by:offset),64)==0 else {throw MeshError.invalidOBJ("History bits mismatch")}}
                    }
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
        let low=(SIMD3<Float>(history.stock_min[0],history.stock_min[1],history.stock_min[2])-origin)/h-SIMD3<Float>(repeating:1)
        var high=(SIMD3<Float>(history.stock_max[0],history.stock_max[1],history.stock_max[2])-origin)/h+SIMD3<Float>(repeating:1)
        high[sectionAxis]=min(high[sectionAxis],Float(history.grid[sectionAxis])*sectionFraction)
        var shank=SIMD4<Float>(repeating:0),shankAxis=SIMD4<Float>(0,0,1,0),holder=shank,holderAxis=shankAxis
        var cutter=SIMD4<Float>(repeating:0),cutterAxis=SIMD4<Float>(0,0,1,0)
        if showHolder,frame>0 {let step=history.frames[frame-1];let axis=step.axis ?? [0,0,1]
            if axis.count==3,step.tool.count==3 {let u=SIMD3<Float>(axis[0],axis[1],axis[2]);let p=SIMD3<Float>(step.tool[0],step.tool[1],step.tool[2]);if let part=step.cutter,(part.kind=="flat" || part.kind=="ball") {cutter=SIMD4((p-origin)/h,part.radius/h);cutterAxis=SIMD4(u,part.length/h)};if let part=step.shank {shank=SIMD4((p+u*part.offset-origin)/h,part.radius/h);shankAxis=SIMD4(u,part.length/h)};if let part=step.holder {holder=SIMD4((p+u*part.offset-origin)/h,part.radius/h);holderAxis=SIMD4(u,part.length/h)}}
        }
        return VoxelUniforms(eye:SIMD4((eye-origin)/h,frame>0 && history.frames[frame-1].cutter?.kind=="ball" ? 1:0),forward:SIMD4(forward,0),right:SIMD4(right,0),up:SIMD4(up,0),low:SIMD4(simd_max(low,SIMD3(repeating:0)),0),high:SIMD4(simd_min(high,SIMD3(Float(history.grid[0]),Float(history.grid[1]),Float(history.grid[2]))),0),settings:SIMD4(h,Float(width),Float(height),tan(Float.pi/8)),grid:SIMD4(showStock ? 1:0,UInt32(history.grid[0]),darkBackground ? 1:0,smoothLighting ? 1:0),dimensions:SIMD4(UInt32(history.grid[0]),UInt32(history.grid[1]),UInt32(history.grid[2]),compareTarget && targetBlocks != nil ? 1:0),blockDimensions:SIMD4(UInt32(history.block_grid[0]),UInt32(history.block_grid[1]),UInt32(history.block_grid[2]),showFixtures && fixtureBlocks != nil ? 1:0),shank:shank,shankAxis:shankAxis,holder:holder,holderAxis:holderAxis,cutter:cutter,cutterAxis:cutterAxis,provenance:SIMD4(provenanceCount,provenanceAvailableAtFrame && !compareTarget ? provenanceMode:0,UInt32(frame),0))
    }
    func encode(_ texture:MTLTexture)->MTLCommandBuffer? {
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else {return nil}
        var u=uniforms(width:texture.width,height:texture.height)
        encoder.setBuffer(targetBlocks ?? blocks,offset:0,index:3);encoder.setBuffer(targetPool ?? pool,offset:0,index:4)
        encoder.setBuffer(fixtureBlocks ?? blocks,offset:0,index:5);encoder.setBuffer(fixturePool ?? pool,offset:0,index:6)
        encoder.setBuffer(provenanceBuffer ?? pool,offset:0,index:7)
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
        let stage=frame==0 ? "Initial stock":frame==history.frames.count ? "Complete":history.frames[frame-1].stage
        let approximation=history.motion_tolerance_mm.map {String(format:" · motion budget %.4f mm",$0)} ?? ""
        let toolNotice = frame>0 && history.frames[frame-1].cutter?.kind == "profile" ? " · profile wheel display unavailable" : ""
        return "\(stage)\(toolNotice) · \(frame)/\(history.frames.count) · \(history.grid[0]) × \(history.grid[1]) × \(history.grid[2]) · \(String(format:"%.3f",history.voxel_mm*1000)) µm · \(occupied.formatted()) occupied · GPU \(String(format:"%.1f",lastGPUms)) ms\(approximation)\(provenanceMode == 0 ? "" : (provenanceAvailableAtFrame && !compareTarget ? (provenanceAllFrames ? " · playback surface provenance":" · final surface provenance") : " · provenance inactive (final state only; target comparison takes precedence)")) · \(picked)"
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
    var findings=[Finding]()
    var visibleFindings=[Finding]()
    let findingSearch=NSSearchField()
    let findingMenu=NSPopUpButton()
    let findingDetail=NSTextField(wrappingLabelWithString:"")
    let sectionControl=NSSlider(value:1,minValue:0.000001,maxValue:1,target:nil,action:nil)
    let axesControl=NSPopUpButton()
    let stockControl=NSButton(checkboxWithTitle:"Stock",target:nil,action:nil)
    let fixtureControl=NSButton(checkboxWithTitle:"Fixtures",target:nil,action:nil)
    let holderControl=NSButton(checkboxWithTitle:"Tool assembly",target:nil,action:nil)
    let comparisonControl=NSButton(checkboxWithTitle:"Target: excess yellow / missing red",target:nil,action:nil)
    let play=NSButton(title:"Pause",target:nil,action:nil);var playing=true;var timer:Timer?
    init(_ r:VoxelRenderer) {renderer=r;metal=VoxelMetalView(frame:.zero,device:r.device);super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError("No storyboard")}
    override func loadView() {
        view=NSView(frame:NSRect(x:0,y:0,width:1280,height:900))
        metal.frame=view.bounds;metal.autoresizingMask=[.width,.height];metal.framebufferOnly=false;metal.colorPixelFormat = .bgra8Unorm;metal.delegate=renderer;metal.renderer=renderer;metal.preferredFramesPerSecond=60
        view.addSubview(metal)
        let title=NSTextField(labelWithString:"MENKH / VOXEL CUTTING");title.font = .systemFont(ofSize:19,weight:.bold);title.textColor = .white
        let help=NSTextField(labelWithString:"Drag: orbit · Scroll: zoom · Double-click: focus surface · Shift + drag: pan");help.textColor = .white
        let reset=NSButton(title:"Reset camera",target:self,action:#selector(resetCamera))
        let lighting=NSButton(checkboxWithTitle:"Average normals (lighting only)",target:self,action:#selector(lighting(_:)))
        lighting.state=renderer.smoothLighting ? .on : .off
        let background=NSButton(checkboxWithTitle:"Dark background",target:self,action:#selector(background(_:)))
        let restart=NSButton(title:"Restart",target:self,action:#selector(restart))
        play.target=self;play.action=#selector(toggle);slider.target=self;slider.action=#selector(scrub);slider.isContinuous=true;slider.maxValue=Double(renderer.history.frames.count)
        status.textColor = .white;status.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
        let stock=stockControl;stock.target=self;stock.action=#selector(stock(_:));stock.state = .on
        let comparison=comparisonControl;comparison.target=self;comparison.action=#selector(compare(_:))
        comparison.isEnabled=renderer.targetBlocks != nil
        let section=sectionControl;section.target=self;section.action=#selector(section(_:));section.toolTip="Z cross-section";section.widthAnchor.constraint(equalToConstant:120).isActive=true
        let fixtures=fixtureControl;fixtures.target=self;fixtures.action=#selector(fixtures(_:));fixtures.state = .on;fixtures.isEnabled=renderer.fixtureBlocks != nil
        let holder=holderControl;holder.target=self;holder.action=#selector(holder(_:));holder.state = renderer.showHolder ? .on:.off
        let buttons=NSStackView(views:[play,restart,reset,lighting,background]);buttons.spacing=12
        let axes=axesControl;axes.addItems(withTitles:["Section X","Section Y","Section Z"]);axes.selectItem(at:renderer.sectionAxis);axes.target=self;axes.action=#selector(sectionAxis(_:))
        let provenance=NSPopUpButton();provenance.addItems(withTitles:["Material color","Exposure operation","Exposure tool"]);provenance.isEnabled=renderer.provenanceBuffer != nil;provenance.target=self;provenance.action=#selector(provenance(_:))
        buttons.addArrangedSubview(provenance)
        let inspection=NSStackView(views:[stock,comparison,fixtures,holder,axes,section]);inspection.spacing=12
        do {findings=try renderer.loadFindings();filterFindings()}
        catch {findingDetail.stringValue="Inspection unavailable: \(error)"}
        findingSearch.placeholderString="Filter: missing, unresolved, holder, operation ID…";findingSearch.target=self;findingSearch.action=#selector(filterFindings);findingSearch.sendsSearchStringImmediately=true;findingSearch.widthAnchor.constraint(equalToConstant:460).isActive=true
        findingMenu.target=self;findingMenu.action=#selector(selectFinding(_:));findingMenu.widthAnchor.constraint(equalToConstant:760).isActive=true
        findingDetail.textColor = .white;findingDetail.maximumNumberOfLines=3
        let top=NSStackView(views:[title,help]);top.orientation = .vertical;top.alignment = .leading;top.spacing=8;top.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(top)
        let bottom=NSStackView(views:[findingSearch,findingMenu,findingDetail,status,slider,buttons,inspection]);bottom.orientation = .vertical;bottom.alignment = .leading;bottom.spacing=10;bottom.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(bottom)
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),top.topAnchor.constraint(equalTo:view.topAnchor,constant:20),bottom.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),bottom.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-22),bottom.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-22),slider.widthAnchor.constraint(equalTo:bottom.widthAnchor)])
        findingDetail.widthAnchor.constraint(equalTo:bottom.widthAnchor).isActive=true
        status.maximumNumberOfLines=2;status.widthAnchor.constraint(equalTo:bottom.widthAnchor).isActive=true
        refresh();timer=Timer.scheduledTimer(withTimeInterval:1/12,repeats:true) { [weak self] _ in self?.tick() }
    }
    func refresh() {status.stringValue=renderer.label;slider.doubleValue=Double(renderer.frame);play.title=playing ? "Pause":"Play"}
    func seek(_ n:Int) {do {try renderer.seek(n);refresh()}catch{playing=false;status.stringValue="Error: \(error)"}}
    func tick() {if playing {if renderer.frame<renderer.history.frames.count {seek(renderer.frame+1)}else{playing=false}};refresh()}
    @objc func filterFindings() {
        let query=findingSearch.stringValue.lowercased()
        visibleFindings=findings.filter {query.isEmpty || $0.title.lowercased().contains(query)}
        findingMenu.removeAllItems();findingMenu.addItems(withTitles:["Select a finding (\(visibleFindings.count) / \(findings.count))"]+visibleFindings.map {$0.title})
    }
    @objc func selectFinding(_ sender:NSPopUpButton) {
        let i=sender.indexOfSelectedItem-1;guard visibleFindings.indices.contains(i) else {return}
        playing=false
        do {try renderer.focusFinding(visibleFindings[i]);findingDetail.stringValue=renderer.picked;sectionControl.doubleValue=Double(renderer.sectionFraction);axesControl.selectItem(at:renderer.sectionAxis);comparisonControl.state=renderer.compareTarget ? .on:.off;stockControl.state=renderer.showStock ? .on:.off;fixtureControl.state=renderer.showFixtures ? .on:.off;holderControl.state=renderer.showHolder ? .on:.off;refresh()}
        catch {findingDetail.stringValue="Cannot focus finding: \(error)"}
    }
    @objc func toggle() {playing.toggle();refresh()}
    @objc func restart() {playing=true;seek(0)}
    @objc func scrub() {playing=false;seek(Int(slider.doubleValue.rounded()))}
    @objc func resetCamera() {renderer.resetView()}
    @objc func provenance(_ sender:NSPopUpButton) {playing=false;renderer.provenanceMode=UInt32(sender.indexOfSelectedItem);if renderer.provenanceMode != 0 && !renderer.provenanceAllFrames {seek(renderer.history.frames.count)};refresh()}
    @objc func stock(_ sender:NSButton) {renderer.showStock=sender.state == .on}
    @objc func fixtures(_ sender:NSButton) {renderer.showFixtures=sender.state == .on}
    @objc func holder(_ sender:NSButton) {renderer.showHolder=sender.state == .on}
    @objc func compare(_ sender:NSButton) {renderer.compareTarget=sender.state == .on}
    @objc func sectionAxis(_ sender:NSPopUpButton) {renderer.sectionAxis=sender.indexOfSelectedItem}
    @objc func section(_ sender:NSSlider) {renderer.sectionFraction=Float(sender.doubleValue)}
    @objc func lighting(_ b:NSButton) {renderer.smoothLighting=b.state == .on}
    @objc func background(_ b:NSButton) {renderer.darkBackground=b.state == .on}
    deinit {timer?.invalidate()}
}
extension Delegate {
    func openVoxels(_ file:URL) throws {
        let loadStart=CFAbsoluteTimeGetCurrent();let renderer=try VoxelRenderer(file);let loadSeconds=CFAbsoluteTimeGetCurrent()-loadStart;let seekStart=CFAbsoluteTimeGetCurrent();let args=CommandLine.arguments
        if calculatedJob && !args.contains("--frame") {try renderer.seek(renderer.history.frames.count)}
        if let i=args.firstIndex(of:"--frame"),i+1<args.count,let frame=Int(args[i+1]) {try renderer.seek(frame)}
        let seekSeconds=CFAbsoluteTimeGetCurrent()-seekStart
        if let i=args.firstIndex(of:"--section-axis"),i+1<args.count,let axis=["x","y","z"].firstIndex(of:args[i+1]) {renderer.sectionAxis=axis}
        if let i=args.firstIndex(of:"--yaw"),i+1<args.count,let value=Float(args[i+1]),value.isFinite {renderer.yaw=value}
        if let i=args.firstIndex(of:"--elevation"),i+1<args.count,let value=Float(args[i+1]),value.isFinite {renderer.elevation=max(-1.5,min(1.5,value))}
        if args.contains("--hide-tool") {renderer.showHolder=false}
        if args.contains("--smooth-lighting") {renderer.smoothLighting=true}
        if args.contains("--compare-target") {renderer.compareTarget=true}
        if let i=args.firstIndex(of:"--section"),i+1<args.count,let value=Float(args[i+1]),value>0,value<=1 {renderer.sectionFraction=value}
        if let i=args.firstIndex(of:"--distance"),i+1<args.count,let distance=Float(args[i+1]),distance.isFinite,distance>0 {renderer.distance=distance}
        if let i=args.firstIndex(of:"--target-z"),i+1<args.count,let z=Float(args[i+1]),z.isFinite {renderer.target.z=z}
        if let i=args.firstIndex(of:"--finding"),i+1<args.count,let index=Int(args[i+1]) {
            let findings=try renderer.loadFindings();guard findings.indices.contains(index) else {throw MeshError.invalidOBJ("Finding index out of range")};try renderer.focusFinding(findings[index]);print(renderer.picked)
        }
        if let i=args.firstIndex(of:"--list-findings"),i+1<args.count {
            let findings=try renderer.loadFindings()
            let rows=try findings.enumerated().map { i,f -> [String:Any] in
                if args.contains("--validate-findings") {try renderer.focusFinding(f)}
                return ["index":i,"title":f.title,"detail":f.detail,"frame":f.frame ?? renderer.history.frames.count,"bounds":["lo":f.bounds.lo,"hi":f.bounds.hi],"section_fraction":max(0.000001,min(1,((f.bounds.lo[2]+f.bounds.hi[2])/2-renderer.origin.z)/(Float(renderer.history.grid[2])*renderer.history.voxel_mm)))]
            }
            try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return
        }
        if args.contains("--color-operation") || args.contains("--color-tool") {guard renderer.provenanceBuffer != nil else {throw MeshError.invalidOBJ("No surface provenance; enable export_provenance in the job")};renderer.provenanceMode=args.contains("--color-tool") ? 2:1;if !args.contains("--frame") {try renderer.seek(renderer.history.frames.count)}}
        if args.contains("--pick-center") {renderer.focus(x:0.5,y:0.5,aspect:1280/900);guard !renderer.picked.isEmpty else {throw MeshError.invalidOBJ("Center pick missed material")}}
        if let i=args.firstIndex(of:"--movie"),i+1<args.count {try renderer.movie(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return}
        if let i=args.firstIndex(of:"--verify-provenance-oracle"),i+1<args.count {try renderer.verifyProvenanceOracle(URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return}
        if let i=args.firstIndex(of:"--verify-history"),i+1<args.count {try renderer.verifyHistory(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return}
        if let i=args.firstIndex(of:"--render-bench"),i+1<args.count {
            var samples=[Double]();for j in 0..<13 {_ = try renderer.image();if j>=3 {samples.append(renderer.lastGPUms)}};samples.sort()
            let record:[String:Any] = ["load_upload_seconds":loadSeconds,"seek_seconds":seekSeconds,"section_axis":renderer.sectionAxis,"grid":renderer.history.grid,"frame":renderer.frame,"width":1280,"height":900,"samples":10,"warmups":3,"gpu_ms_min":samples.first!,"gpu_ms_median":(samples[4]+samples[5])/2,"gpu_ms_max":samples.last!,"averaged_normals":renderer.smoothLighting,"samples_per_pixel":4,"target_comparison":renderer.compareTarget,"provenance_mode":renderer.provenanceMode,"provenance_records":renderer.provenanceCount,"provenance_active":renderer.provenanceMode != 0 && renderer.provenanceAvailableAtFrame && !renderer.compareTarget,"section_fraction":renderer.sectionFraction,"fixtures_visible":renderer.showFixtures,"holder_visible":renderer.showHolder,"note":"GPU command duration only, offscreen static view; not interactive FPS"]
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[i+1]));NSApp.terminate(nil);return
        }
        if let i=args.firstIndex(of:"--snapshot"),i+1<args.count {
            let image=try renderer.image();guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw MeshError.imageEncoding}
            try png.write(to:URL(fileURLWithPath:args[i+1]));print(renderer.label);NSApp.terminate(nil);return
        }
        let controller=VoxelController(renderer)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="menkh — \(renderer.history.grid[0])³ voxel removal";window.contentViewController=controller;window.center();window.makeKeyAndOrderFront(nil);self.window=window;NSApp.activate(ignoringOtherApps:true)
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
        let order=Array(repeating:0,count:12)+Array(0...history.frames.count)+Array(repeating:history.frames.count,count:36)
        for (i,f) in order.enumerated() {
            try autoreleasepool {
                try seek(f)
                if i>12+history.frames.count {
                    let t=Float(i-12-history.frames.count)/36
                    yaw = -0.8+0.35*t
                }
                let image=try image(width:width,height:height)
                image.lockFocus()
                let title:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:22,weight:.bold),.foregroundColor:NSColor.white]
                ("MENKH / CUTTING SIMULATION" as NSString).draw(at:NSPoint(x:24,y:height-44),withAttributes:title)
                let detail:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:14,weight:.medium),.foregroundColor:NSColor.white]
                ("\(frame==0 ? "Initial stock":history.frames[frame-1].stage) · \(frame)/\(history.frames.count) · \(String(format:"%.3f",history.voxel_mm*1000)) µm · voxel stock / CPU cutting" as NSString).draw(at:NSPoint(x:24,y:24),withAttributes:detail)
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
        print("Voxel job video: \(order.count) frames, \(url.path)")
    }
    func occupiedCount()->UInt64 {
        let descriptors=blocks.contents().assumingMemoryBound(to:UInt32.self)
        let words=pool.contents().assumingMemoryBound(to:UInt64.self)
        var count:UInt64=0
        for i in 0..<blocks.length/4 {
            let d=descriptors[i]
            if d==0xfffffffe {let nb=history.block_grid;let b=[i%nb[0],(i/nb[0])%nb[1],i/(nb[0]*nb[1])];count+=UInt64((0..<3).map {min(8,history.grid[$0]-b[$0]*8)}.reduce(1,*))}
            else if d<0xfffffffe {for z in 0..<8 {count+=UInt64(words[Int(d)*8+z].nonzeroBitCount)}}
        }
        return count
    }
    func verifyHistory(to url:URL) throws {
        let started=CFAbsoluteTimeGetCurrent()
        try seek(0);let initial=occupiedCount();guard initial==history.initial_occupied else {throw MeshError.invalidOBJ("Initial count mismatch")}
        try seek(history.frames.count);let final=occupiedCount();guard final==history.final_occupied else {throw MeshError.invalidOBJ("Final count mismatch")}
        let finalBlocks=Data(bytes:blocks.contents(),count:blocks.length);let finalPool=Data(bytes:pool.contents(),count:pool.length)
        // Compare the entire reconstructed initial descriptor array and original pool bytes.
        try seek(0)
        let source=try Data(contentsOf:root.appendingPathComponent("initial.blocks"),options:.mappedIfSafe)
        let bits=try Data(contentsOf:root.appendingPathComponent("initial.pool"),options:.mappedIfSafe)
        let same=source.withUnsafeBytes {memcmp($0.baseAddress!,blocks.contents(),source.count)==0}
        let samePool=bits.withUnsafeBytes {memcmp($0.baseAddress!,pool.contents(),bits.count)==0}
        guard same && samePool else {throw MeshError.invalidOBJ("Backward history differs")}
        try seek(history.frames.count);guard occupiedCount()==final else {throw MeshError.invalidOBJ("Replay differs")}
        let finalExact=finalBlocks.withUnsafeBytes {memcmp($0.baseAddress!,blocks.contents(),blocks.length)==0} && finalPool.withUnsafeBytes {memcmp($0.baseAddress!,pool.contents(),pool.length)==0}
        guard finalExact else {throw MeshError.invalidOBJ("Final replay bytes differ")}
        let record:[String:Any]=["replay_seconds":CFAbsoluteTimeGetCurrent()-started,"shared_buffer_bytes":blocks.length+pool.length+(targetBlocks?.length ?? 0)+(targetPool?.length ?? 0)+(fixtureBlocks?.length ?? 0)+(fixturePool?.length ?? 0)+(provenanceBuffer?.length ?? 0),"final_replay_byte_exact":finalExact,"grid":history.grid,"initial_occupied":initial,"final_occupied":final,"reverse_descriptors_byte_exact":same,"reverse_initial_pool_byte_exact":samePool,"forward_replay_validated":true]
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
        var faceAxis=near.x>near.y ? (near.x>near.z ? 0:2):(near.y>near.z ? 1:2)
        var t=max(0,max(near.x,max(near.y,near.z)));let end=min(far.x,min(far.y,far.z));if t>end {return}
        let n=history.grid;let nb=history.block_grid
        let descriptors=blocks.contents().assumingMemoryBound(to:UInt32.self);let words=pool.contents().assumingMemoryBound(to:UInt64.self)
        for _ in 0..<n.reduce(0,+)+8 {
            let position=eye+ray*(t+0.001);let p=[Int(floor(position.x)),Int(floor(position.y)),Int(floor(position.z))]
            if (0..<3).contains(where:{p[$0]<0 || p[$0]>=n[$0]}) {return}
            let d=descriptors[((p[2]/8)*nb[1]+p[1]/8)*nb[0]+p[0]/8]
            let occupied=d==0xfffffffe || (d<0xfffffffe && (words[Int(d)*8+p[2]%8] & (UInt64(1)<<UInt64(p[1]%8*8+p[0]%8))) != 0)
            if occupied {
                let hit=(eye+ray*t)*history.voxel_mm+origin;let oldEye=eye*history.voxel_mm+origin
                picked=String(format:"occupied @ (%.4f, %.4f, %.4f) mm",hit.x,hit.y,hit.z)
                if provenanceBuffer != nil && provenanceAvailableAtFrame {
                    var neighbor=p;neighbor[faceAxis] += ray[faceAxis]>0 ? -1:1
                    if abs((eye+ray*t)[faceAxis] - round((eye+ray*t)[faceAxis]))<0.01, let (op,tool)=provenanceAt(neighbor) {picked += " · exposed by \(history.frames[Int(op)-1].stage) (operation \(op), tool \(tool == 0 ? "none":String(tool-1)))"}
                    else {picked += " · initial/prehistory boundary or section interior"}
                }
                let offset=oldEye-hit;let length=simd_length(offset)
                if length>0.01 {target=hit;distance=length;yaw=atan2(offset.y,offset.x);elevation=asin(offset.z/length)}
                return
            }
            let step=d==0xffffffff ? 8:1
            var next=SIMD3<Float>();for j in 0..<3 {let edge=Float((p[j]/step)*step+(ray[j]>0 ? step:0));next[j]=(edge-eye[j])*inverse[j]}
            faceAxis=next.x<next.y ? (next.x<next.z ? 0:2):(next.y<next.z ? 1:2)
            t=max(min(next.x,min(next.y,next.z)),t+0.001);if t>end {return}
        }
    }
}

extension VoxelRenderer {
    func resetView() {
        let low=SIMD3<Float>(history.stock_min[0],history.stock_min[1],history.stock_min[2]);let high=SIMD3<Float>(history.stock_max[0],history.stock_max[1],history.stock_max[2])
        target=(low+high)/2;distance=max(1,simd_length(high-low)*1.5);yaw = -0.8;elevation=0.5;roll=0
    }
}
