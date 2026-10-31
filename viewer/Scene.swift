import AppKit

struct SceneResult:Decodable {
    struct Object:Decodable {let id:String;let role:String;let translation_mm:[Double]}
    struct Result:Decodable {let object_id:String;let translation_mm:[Double];let history:String}
    let format:String;let units:String;let objects:[Object];let results:[Result]
    func validate() throws {
        guard format=="menkh-scene-result-v1",units=="mm",!results.isEmpty,
              Set(objects.map{$0.id}).count==objects.count,Set(results.map{$0.object_id}).count==results.count else {throw MeshError.invalidOBJ("Invalid scene result")}
        for result in results {
            guard let object=objects.first(where:{$0.id==result.object_id}),object.role=="workpiece",
                  result.translation_mm.count==3,result.translation_mm.allSatisfy({$0.isFinite}),object.translation_mm==result.translation_mm else {throw MeshError.invalidOBJ("Invalid scene workpiece binding")}
        }
    }
}
extension Delegate {
    func openScene(_ file:URL) throws {
        let scene=try JSONDecoder().decode(SceneResult.self,from:Data(contentsOf:file));try scene.validate()
        let selected:Int
        if let id=try JobRunner.argument("--workpiece") {
            guard let index=scene.results.firstIndex(where:{$0.object_id==id}) else {throw MeshError.invalidOBJ("Unknown workpiece ID: \(id)")};selected=index
        } else if scene.results.count==1 {selected=0}
        else {
            let alert=NSAlert();alert.messageText="Select a workpiece";alert.informativeText="Each workpiece has its own material and history. Inspection coordinates are local to that workpiece."
            alert.addButton(withTitle:"Open");alert.addButton(withTitle:"Cancel")
            let menu=NSPopUpButton(frame:NSRect(x:0,y:0,width:360,height:28));menu.addItems(withTitles:scene.results.map{$0.object_id});alert.accessoryView=menu
            guard alert.runModal() == .alertFirstButtonReturn else {NSApp.terminate(nil);return};selected=menu.indexOfSelectedItem
        }
        let result=scene.results[selected],parts=result.history.split(separator:"/",omittingEmptySubsequences:false)
        guard !result.history.contains("\\"),!result.history.contains(":"),parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else {throw MeshError.invalidOBJ("Invalid scene history path")}
        let root=file.deletingLastPathComponent().resolvingSymlinksInPath()
        let history=root.appendingPathComponent(result.history).resolvingSymlinksInPath()
        guard history.path.hasPrefix(root.path+"/") else {throw MeshError.invalidOBJ("Scene history escapes its result directory")}
        sceneContext="Workpiece \(result.object_id) · local coordinates · scene translation \(result.translation_mm) mm"
        print(sceneContext)
        try openVoxels(history)
    }
}
