import AppKit
import SceneKit
import Metal
import AVFoundation
import simd

struct DrillFrame: Decodable {
    let file: String
    let stage: String
    let occupied: UInt64
    let tool: [Float]
    let quads: Int
}
struct DrillManifest: Decodable {
    let format: String
    let voxel_mm: Float
    let cutter_radius_mm: Float
    let fps: Double
    let frames: [DrillFrame]
}
final class DrillPlayback {
    let manifest: DrillManifest
    let root: URL
    let scene = SCNScene()
    let stock = SCNNode()
    let tool = SCNNode()
    let plane = SCNNode()
    let camera = SCNNode()
    let material = SCNMaterial()
    var frame = 0
    var cache = [Int: SCNGeometry]()
    init(_ url: URL) throws {
        root = url.deletingLastPathComponent()
        manifest = try JSONDecoder().decode(DrillManifest.self, from: Data(contentsOf:url))
        guard manifest.format == "menkh-quads-v1", !manifest.frames.isEmpty, manifest.voxel_mm.isFinite, manifest.voxel_mm > 0, manifest.fps > 0 else { throw MeshError.invalidOBJ("Invalid animation manifest") }
        for f in manifest.frames { guard f.tool.count == 3, f.tool.allSatisfy({$0.isFinite}), f.file == URL(fileURLWithPath:f.file).lastPathComponent else { throw MeshError.invalidOBJ("Invalid animation frame") } }
        scene.background.contents = NSColor(calibratedRed:0.035,green:0.045,blue:0.065,alpha:1)
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(calibratedRed:0.62,green:0.71,blue:0.78,alpha:1)
        material.specular.contents = NSColor(calibratedWhite:0.75,alpha:1)
        material.shininess = 70
        scene.rootNode.addChildNode(stock)
        camera.camera = SCNCamera(); camera.camera?.zNear = 0.1; camera.camera?.zFar = 1000; camera.camera?.fieldOfView = 38
        scene.rootNode.addChildNode(camera); resetCamera()
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 250
        scene.rootNode.addChildNode(ambient)
        for (p,power) in [(SCNVector3(40,-40,90),CGFloat(1050)),(SCNVector3(-40,20,40),CGFloat(550))] {
            let n = SCNNode(); n.light = SCNLight(); n.light?.type = .directional; n.light?.intensity = power
            n.position = p; n.look(at:SCNVector3(6,6,30),up:SCNVector3(0,0,1),localFront:SCNVector3(0,0,-1)); scene.rootNode.addChildNode(n)
        }
        let orange = SCNMaterial(); orange.diffuse.contents = NSColor(calibratedRed:1,green:0.48,blue:0.08,alpha:1); orange.lightingModel = .blinn
        orange.transparency = 0.65; orange.readsFromDepthBuffer = false; orange.writesToDepthBuffer = false
        let ball = SCNSphere(radius:CGFloat(manifest.cutter_radius_mm)); ball.segmentCount = 32; ball.materials = [orange]
        tool.geometry = ball; tool.renderingOrder = 20; scene.rootNode.addChildNode(tool)
        let facet = SCNBox(width:16,height:12,length:0.25,chamferRadius:0); facet.materials = [orange]; plane.geometry = facet; plane.renderingOrder = 20; scene.rootNode.addChildNode(plane)
        let chuck = SCNCylinder(radius:8,height:8); let dark = SCNMaterial(); dark.diffuse.contents = NSColor(calibratedWhite:0.16,alpha:1); dark.lightingModel = .blinn; chuck.materials = [dark]
        let holder = SCNNode(geometry:chuck);holder.position = SCNVector3(6,6,-4);holder.eulerAngles.x = .pi/2;scene.rootNode.addChildNode(holder)
        try show(0)
    }
    func resetCamera() {
        camera.position = SCNVector3(83,-113,69)
        camera.look(at:SCNVector3(6,6,27),up:SCNVector3(0,0,1),localFront:SCNVector3(0,0,-1))
    }
    func geometry(_ index: Int) throws -> SCNGeometry {
        if let cached = cache[index] { return cached }
        let item = manifest.frames[index]
        let data = try Data(contentsOf:root.appendingPathComponent(item.file))
        guard item.quads > 0, item.quads <= 5_000_000, data.count == item.quads * 12 else { throw MeshError.invalidOBJ("Corrupt quad frame") }
        var vertices = [SCNVector3]();var normals = [SCNVector3]();var indices = [UInt32]()
        vertices.reserveCapacity(item.quads*4);normals.reserveCapacity(item.quads*4);indices.reserveCapacity(item.quads*6)
        data.withUnsafeBytes { (bytes:UnsafeRawBufferPointer) in
            for i in 0..<item.quads {
                let o = i*12
                func u16(_ j:Int) -> Int { Int(bytes[o+j]) | Int(bytes[o+j+1])<<8 }
                let axis = Int(bytes[o+10]);let positive = bytes[o+11] != 0
                if axis > 2 { continue }
                let u = (axis+1)%3;let v = (axis+2)%3
                let p = [u16(0),u16(2),u16(4)];let w = u16(6);let h = u16(8)
                var normal = [Float](repeating:0,count:3);normal[axis] = positive ? 1 : -1
                let base = UInt32(vertices.count)
                for offset in [(0,0),(w,0),(w,h),(0,h)] {
                    var q = p;q[u] += offset.0;q[v] += offset.1
                    vertices.append(SCNVector3(Float(q[0])*manifest.voxel_mm,Float(q[1])*manifest.voxel_mm,Float(q[2])*manifest.voxel_mm))
                    normals.append(SCNVector3(normal[0],normal[1],normal[2]))
                }
                indices.append(contentsOf:positive ? [base,base+1,base+2,base,base+2,base+3] : [base+2,base+1,base,base+3,base+2,base])
            }
        }
        guard indices.count == item.quads*6 else { throw MeshError.invalidOBJ("Invalid quad axis") }
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        g.materials = [material]
        cache = cache.filter { abs($0.key-index) <= 1 };cache[index] = g
        return g
    }
    func show(_ index:Int) throws {
        let g = try geometry(index);frame = index
        SCNTransaction.begin();SCNTransaction.animationDuration = 0;SCNTransaction.disableActions = true
        stock.geometry = g
        let f = manifest.frames[index]
        tool.position = SCNVector3(f.tool[0],f.tool[1],f.tool[2])
        let tip = f.stage.contains("facettieren")
        tool.isHidden = index == 0 || tip || index == manifest.frames.count-1
        plane.isHidden = !tip || index == manifest.frames.count-1
        if tip {
            let angle = atan2(f.tool[1]-6,f.tool[0]-6)
            plane.position = SCNVector3(6+3*cos(angle),6+3*sin(angle),57)
            plane.simdOrientation = simd_quatf(from:SIMD3<Float>(0,0,1),to:simd_normalize(SIMD3<Float>(cos(angle),sin(angle),1)))
        }
        SCNTransaction.commit()
    }
    var label:String {
        let item = manifest.frames[frame]
        let removed = Double(manifest.frames[0].occupied-item.occupied)*pow(Double(manifest.voxel_mm),3)
        return "\(item.stage)  ·  \(frame)/\(manifest.frames.count-1)  ·  \(String(format:"%.1f",removed)) mm³ abgetragen"
    }
    func snapshot(_ renderer:SCNRenderer, size:CGSize) -> NSImage {
        let image = renderer.snapshot(atTime:Double(frame)/manifest.fps,with:size,antialiasingMode:.multisampling4X)
        image.lockFocus()
        let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:22,weight:.semibold),.foregroundColor:NSColor.white]
        ("MENKH  /  Vom Zylinder zum Spiralbohrer" as NSString).draw(at:NSPoint(x:28,y:size.height-48),withAttributes:attrs)
        let small:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor(calibratedWhite:0.8,alpha:1)]
        (label as NSString).draw(at:NSPoint(x:28,y:36),withAttributes:small)
        ("Geometrische Voxel-Demo · Raster \(manifest.voxel_mm) mm" as NSString).draw(at:NSPoint(x:28,y:16),withAttributes:small)
        image.unlockFocus();return image
    }
    func movie(to url:URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MeshError.noMetal }
        let renderer = SCNRenderer(device:device,options:nil);renderer.scene = scene;renderer.pointOfView = camera
        let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        let width = 960;let height = 960
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
        input.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(input);guard writer.startWriting() else { throw writer.error ?? MeshError.imageEncoding };writer.startSession(atSourceTime:.zero)
        // One second of initial stock, twelve simulation states/s, three seconds of final result.
        let order = Array(repeating:0,count:12) + Array(manifest.frames.indices) + Array(repeating:manifest.frames.count-1,count:36)
        for (i,f) in order.enumerated() {
            try autoreleasepool {
                try show(f)
                let image = snapshot(renderer,size:CGSize(width:width,height:height))
                var rect = CGRect(x:0,y:0,width:width,height:height)
                guard let cg = image.cgImage(forProposedRect:&rect,context:nil,hints:nil),let pool = adapter.pixelBufferPool else { throw MeshError.imageEncoding }
                var buffer:CVPixelBuffer?;guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess,let pixel = buffer else { throw MeshError.imageEncoding }
                CVPixelBufferLockBaseAddress(pixel,[]);defer {CVPixelBufferUnlockBaseAddress(pixel,[])}
                guard let context = CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw MeshError.imageEncoding }
                context.draw(cg,in:rect)
                let deadline = Date().addingTimeInterval(20)
                while !input.isReadyForMoreMediaData { if writer.status == .failed || Date() > deadline { throw writer.error ?? MeshError.imageEncoding };Thread.sleep(forTimeInterval:0.002) }
                guard adapter.append(pixel,withPresentationTime:CMTime(value:Int64(i),timescale:12)) else { throw writer.error ?? MeshError.imageEncoding }
            }
        }
        input.markAsFinished();let done = DispatchSemaphore(value:0);writer.finishWriting {done.signal()};done.wait()
        guard writer.status == .completed else { throw writer.error ?? MeshError.imageEncoding }
        print("Animation exported: \(url.path), \(order.count) frames at 12 fps")
    }
}
final class DrillController:NSViewController {
    let playback:DrillPlayback
    let sceneView = SCNView()
    let status = NSTextField(labelWithString:"")
    let play = NSButton(title:"Pause",target:nil,action:nil)
    let slider = NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil)
    var timer:Timer?
    var playing = true
    init(_ playback:DrillPlayback) {self.playback = playback;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError("No storyboard")}
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:1100,height:850))
        sceneView.frame = view.bounds;sceneView.autoresizingMask = [.width,.height];sceneView.scene = playback.scene;sceneView.pointOfView = playback.camera
        sceneView.allowsCameraControl = true;sceneView.antialiasingMode = .multisampling4X
        sceneView.defaultCameraController.worldUp = SCNVector3(0,0,1);sceneView.defaultCameraController.target = SCNVector3(6,6,27);sceneView.defaultCameraController.interactionMode = .orbitTurntable
        view.addSubview(sceneView)
        let title = NSTextField(labelWithString:"MENKH  /  Vom Zylinder zum Spiralbohrer");title.font = .systemFont(ofSize:22,weight:.semibold);title.textColor = .white
        let detail = NSTextField(labelWithString:"Echter Voxelabtrag · Zwei helikale Nuten + Spitze · Geometrische Demo");detail.textColor = .lightGray
        play.target = self;play.action = #selector(toggle)
        let restart = NSButton(title:"Neu starten",target:self,action:#selector(restart))
        let reset = NSButton(title:"Kamera zurücksetzen",target:self,action:#selector(resetCamera))
        let buttons = NSStackView(views:[play,restart,reset]);buttons.spacing = 12
        slider.maxValue = Double(playback.manifest.frames.count-1);slider.target = self;slider.action = #selector(scrub);slider.isContinuous = true
        status.textColor = .white;status.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular)
        let top = NSStackView(views:[title,detail]);top.orientation = .vertical;top.alignment = .leading;top.spacing = 8;top.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(top)
        let bottom = NSStackView(views:[status,slider,buttons]);bottom.orientation = .vertical;bottom.alignment = .leading;bottom.spacing = 12;bottom.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(bottom)
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),top.topAnchor.constraint(equalTo:view.topAnchor,constant:24),bottom.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),bottom.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),bottom.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-24),slider.widthAnchor.constraint(equalTo:bottom.widthAnchor)])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval:1/playback.manifest.fps,repeats:true) { [weak self] _ in self?.tick() }
    }
    func refresh() {status.stringValue = playback.label;slider.doubleValue = Double(playback.frame);play.title = playing ? "Pause" : "Abspielen"}
    func seek(_ index:Int) {do {try playback.show(index);refresh()} catch {playing = false;status.stringValue = "Ladefehler: \(error)"}}
    func tick() {guard playing else {return};if playback.frame+1 >= playback.manifest.frames.count {playing = false;refresh();return};seek(playback.frame+1)}
    @objc func toggle() {playing.toggle();refresh()}
    @objc func restart() {playing = true;seek(0)}
    @objc func scrub() {playing = false;seek(Int(slider.doubleValue.rounded()))}
    @objc func resetCamera() {sceneView.defaultCameraController.stopInertia();playback.resetCamera();sceneView.pointOfView = playback.camera}
    deinit {timer?.invalidate()}
}
extension Delegate {
    func openDrill(_ file:URL) throws {
        let playback = try DrillPlayback(file)
        let args = CommandLine.arguments
        if let at = args.firstIndex(of:"--frame"),at+1<args.count,let frame = Int(args[at+1]) {
            guard playback.manifest.frames.indices.contains(frame) else {throw MeshError.invalidOBJ("Frame out of range")};try playback.show(frame)
        }
        if let at = args.firstIndex(of:"--snapshot"),at+1<args.count {
            guard let device = MTLCreateSystemDefaultDevice() else {throw MeshError.noMetal}
            let renderer = SCNRenderer(device:device,options:nil);renderer.scene = playback.scene;renderer.pointOfView = playback.camera
            let image = playback.snapshot(renderer,size:CGSize(width:1100,height:1000))
            guard let tiff = image.tiffRepresentation,let bitmap = NSBitmapImageRep(data:tiff),let png = bitmap.representation(using:.png,properties:[:]) else {throw MeshError.imageEncoding}
            try png.write(to:URL(fileURLWithPath:args[at+1]));NSApp.terminate(nil);return
        }
        if let at = args.firstIndex(of:"--movie"),at+1<args.count {try playback.movie(to:URL(fileURLWithPath:args[at+1]));NSApp.terminate(nil);return}
        let controller = DrillController(playback)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "menkh — Spiralbohrer fräsen";window.contentViewController = controller;window.center();window.makeKeyAndOrderFront(nil);self.window = window
        NSApp.activate(ignoringOtherApps:true)
    }
}
