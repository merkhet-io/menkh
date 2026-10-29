import AppKit
import SceneKit
import Metal
import simd

// A standalone viewer for menkh's deliberately small OBJ subset (vertices + quad faces).
// No simulation state or Zig runtime is linked into this executable.
enum MeshError: Error { case invalidOBJ(String), noMetal, imageEncoding }
func readMesh(_ url: URL) throws -> (SCNGeometry, Int) {
    let text = try String(contentsOf: url, encoding: .utf8)
    var points = [SIMD3<Float>]()
    var normals = [SCNVector3]()
    var vertices = [SCNVector3]()
    var indices = [UInt32]()
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let kind = fields.first else { continue }
        if kind == "v" {
            guard fields.count == 4, let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3]), x.isFinite, y.isFinite, z.isFinite else { throw MeshError.invalidOBJ("Invalid vertex") }
            points.append(SIMD3(x,y,z))
        } else if kind == "f" {
            guard fields.count == 5, vertices.count <= Int(UInt32.max)-4 else { throw MeshError.invalidOBJ("Expected quad face") }
            var face = [SIMD3<Float>]()
            for token in fields.dropFirst() {
                guard let index = Int(token), index > 0, index <= points.count else { throw MeshError.invalidOBJ("Invalid face index") }
                face.append(points[index-1])
            }
            let cross = simd_cross(face[1]-face[0], face[2]-face[0])
            guard simd_length_squared(cross) > 0 else { throw MeshError.invalidOBJ("Degenerate quad") }
            let normal = simd_normalize(cross)
            let base = UInt32(vertices.count)
            for p in face { vertices.append(SCNVector3(p.x,p.y,p.z)); normals.append(SCNVector3(normal.x,normal.y,normal.z)) }
            indices.append(contentsOf: [base,base+1,base+2,base,base+2,base+3])
        }
    }
    guard !indices.isEmpty else { throw MeshError.invalidOBJ("Empty surface") }
    let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: [element])
    let metal = SCNMaterial()
    metal.diffuse.contents = NSColor(calibratedRed: 0.24, green: 0.65, blue: 0.72, alpha: 1)
    metal.lightingModel = .physicallyBased
    metal.metalness.contents = 0.35
    metal.roughness.contents = 0.5
    metal.isDoubleSided = false
    geometry.materials = [metal]
    return (geometry, indices.count / 3)
}
func makeScene(_ geometry: SCNGeometry) -> (SCNScene, SCNNode, SCNNode) {
    let scene = SCNScene()
    scene.background.contents = NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.08, alpha: 1)
    scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    let camera = SCNNode(); camera.camera = SCNCamera()
    camera.camera?.zNear = 0.1; camera.camera?.zFar = 2000
    camera.camera?.fieldOfView = 43
    scene.rootNode.addChildNode(camera)
    reset(camera)
    let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
    ambient.light?.intensity = 220; ambient.light?.color = NSColor(calibratedWhite: 0.8, alpha: 1)
    scene.rootNode.addChildNode(ambient)
    for (position, intensity) in [(SCNVector3(0,-20,65),CGFloat(1700)),(SCNVector3(65,50,35),CGFloat(950))] {
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional; light.light?.intensity = intensity
        light.position = position
        light.look(at: SCNVector3(20,15,0), up: SCNVector3(0,0,1), localFront: SCNVector3(0,0,-1))
        scene.rootNode.addChildNode(light)
    }
    // Display annotation, deliberately lifted 0.08 mm above the floor to prevent z-fighting.
    let path = SCNNode(); path.name = "Example toolpath"
    let pathMaterial = SCNMaterial(); pathMaterial.lightingModel = .constant
    pathMaterial.diffuse.contents = NSColor(calibratedRed: 1, green: 0.58, blue: 0.16, alpha: 1)
    let tube = SCNCylinder(radius: 0.07, height: 20); tube.radialSegmentCount = 12; tube.materials = [pathMaterial]
    let line = SCNNode(geometry: tube); line.position = SCNVector3(20,15,6.08); line.eulerAngles.z = .pi/2
    path.addChildNode(line)
    for x: Float in [10,30] {
        let sphere = SCNSphere(radius: 0.17); sphere.segmentCount = 12; sphere.materials = [pathMaterial]
        let dot = SCNNode(geometry: sphere); dot.position = SCNVector3(x,15,6.08); path.addChildNode(dot)
    }
    scene.rootNode.addChildNode(path)
    return (scene,camera,path)
}
func reset(_ camera: SCNNode) {
    camera.position = SCNVector3(58,-38,90)
    camera.look(at: SCNVector3(20,15,4), up: SCNVector3(0,0,1), localFront: SCNVector3(0,0,-1))
}
class Viewer: NSViewController {
    let sceneView = SCNView()
    let camera: SCNNode
    let path: SCNNode
    let status: String
    init(scene: SCNScene, camera: SCNNode, path: SCNNode, status: String) {
        self.camera = camera; self.path = path; self.status = status
        super.init(nibName: nil,bundle: nil)
        sceneView.scene = scene; sceneView.pointOfView = camera
    }
    required init?(coder: NSCoder) { fatalError("Not a storyboard application") }
    override func loadView() {
        view = NSView(frame: NSRect(x:0,y:0,width:1100,height:760))
        sceneView.frame = view.bounds; sceneView.autoresizingMask = [.width,.height]
        sceneView.antialiasingMode = .multisampling4X; sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.worldUp = SCNVector3(0,0,1)
        sceneView.defaultCameraController.target = SCNVector3(20,15,4)
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        view.addSubview(sceneView)
        let title = NSTextField(labelWithString: "MENKH  /  Voxel machining")
        title.font = .systemFont(ofSize: 21, weight: .semibold); title.textColor = .white
        let detail = NSTextField(labelWithString: status + "\nZiehen: drehen · Scrollen: zoomen · R: Kamera zurücksetzen")
        detail.font = .systemFont(ofSize: 12); detail.textColor = NSColor(calibratedWhite:0.75,alpha:1)
        detail.maximumNumberOfLines = 2
        let resetButton = NSButton(title: "Kamera zurücksetzen", target: self, action: #selector(resetCamera))
        resetButton.bezelStyle = .rounded
        let pathButton = NSButton(checkboxWithTitle: "Beispielbahn (Z = 6 mm)", target: self, action: #selector(togglePath(_:)))
        pathButton.state = .on
        let stack = NSStackView(views: [title,detail,resetButton,pathButton]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:22)])
    }
    @objc func resetCamera() {
        sceneView.defaultCameraController.stopInertia()
        reset(camera); sceneView.pointOfView = camera
    }
    @objc func togglePath(_ button: NSButton) { path.isHidden = button.state != .on }
}
class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var controller: Viewer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            var file: URL
            if CommandLine.arguments.count > 1 { file = URL(fileURLWithPath:CommandLine.arguments[1]) }
            else {
                let panel = NSOpenPanel(); panel.title = "Voxeloberfläche öffnen (menkh OBJ)"; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let selected = panel.url else { NSApp.terminate(nil); return }
                file = selected
            }
            if file.pathExtension == "json" {
                let header = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                if header?["format"] as? String == "menkh-voxel-history-v1" { try openVoxels(file) } else { try openDrill(file) }; return
            }
            let start = Date()
            let (geometry, triangles) = try readMesh(file)
            let (scene,camera,path) = makeScene(geometry)
            let loadSeconds = Date().timeIntervalSince(start)
            if CommandLine.arguments.count == 4 && CommandLine.arguments[2] == "--snapshot" {
                guard let device = MTLCreateSystemDefaultDevice() else { throw MeshError.noMetal }
                let renderer = SCNRenderer(device:device,options:nil); renderer.scene = scene; renderer.pointOfView = camera
                let image = renderer.snapshot(atTime:0,with:CGSize(width:1400,height:1000),antialiasingMode:.multisampling4X)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) else { throw MeshError.imageEncoding }
                try png.write(to:URL(fileURLWithPath:CommandLine.arguments[3]))
                print("Loaded \(triangles) triangles in \(loadSeconds) s; snapshot written")
                NSApp.terminate(nil); return
            }
            controller = Viewer(scene:scene,camera:camera,path:path,status:"\(triangles.formatted()) Dreiecke · Rasteroberfläche, ohne Glättung · mm")
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title = "menkh — \(file.lastPathComponent)"; window.contentViewController = controller
            window.center(); window.makeKeyAndOrderFront(nil); self.window = window
            NSApp.activate(ignoringOtherApps:true)
            NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                if event.charactersIgnoringModifiers?.lowercased() == "r" { self?.controller?.resetCamera(); return nil }
                return event
            }
            print("Loaded \(triangles) triangles in \(loadSeconds) s")
        } catch { fputs("viewer: \(error)\n",stderr); exit(1) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
appMenu.addItem(withTitle:"Beenden",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
let delegate = Delegate(); app.delegate = delegate
app.run()
