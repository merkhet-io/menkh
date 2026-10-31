import Foundation
import simd

struct Finding {
    let title:String
    let detail:String
    let bounds:FindingBounds
    let frame:Int?
}
struct FindingBounds:Decodable {
    let lo:[Float];let hi:[Float]
    var valid:Bool {lo.count==3 && hi.count==3 && zip(lo,hi).allSatisfy {$0.isFinite && $1.isFinite && $0 <= $1}}
}
private struct DefectRegion:Decodable {let kind:String;let voxels:UInt64;let volume_mm3:Double;let bounds:FindingBounds}
private struct DefectFile:Decodable {let format:String;let grid:[Int];let origin_mm:[Float];let voxel_mm:Float;let remaining_occupied:UInt64;let motion_tolerance_mm:Float;let regions:[DefectRegion]}
private struct FindingContact:Decodable {let clearance:String?;let occupied_centers:UInt64;let region:FindingBounds?;let first_unresolved_cell_bounds:FindingBounds?}
private struct FindingOperation:Decodable {
    let id:String
    let shank_stock:FindingContact;let holder_stock:FindingContact
    let shank_fixture:FindingContact;let holder_fixture:FindingContact;let cutter_fixture:FindingContact
}
private struct FindingReport:Decodable {let format:String;let voxel_mm:Float;let origin_mm:[Float];let remaining_occupied:UInt64;let operations:[FindingOperation];let first_operation:Int?}

extension VoxelRenderer {
    func loadFindings() throws -> [Finding] {
        var findings=[Finding]()
        let decoder=JSONDecoder()
        let defects=root.appendingPathComponent("defects.json")
        if FileManager.default.fileExists(atPath:defects.path) {
            let d=try decoder.decode(DefectFile.self,from:Data(contentsOf:defects))
            guard d.format=="menkh-defects-v1", d.grid==history.grid, d.origin_mm==(history.origin_mm ?? [0,0,0]), d.voxel_mm==history.voxel_mm, d.remaining_occupied==history.final_occupied, d.motion_tolerance_mm==history.motion_tolerance_mm else {throw MeshError.invalidOBJ("Defects do not match history")}
            for (i,r) in d.regions.enumerated() {
                guard r.bounds.valid, ["excess","missing"].contains(r.kind), r.voxels>0, r.volume_mm3.isFinite, r.volume_mm3>0 else {throw MeshError.invalidOBJ("Invalid defect region")}
                findings.append(Finding(title:"\(r.kind.capitalized) region \(i+1) · \(r.voxels) voxels",detail:String(format:"%.6g mm³ · final state; responsible operation unknown",r.volume_mm3),bounds:r.bounds,frame:nil))
            }
        }
        let report=root.appendingPathComponent("report.json")
        if FileManager.default.fileExists(atPath:report.path) {
            // Drill histories have a different report schema and no general-job contacts.
            let data=try Data(contentsOf:report)
            let header=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            if header?["format"] as? String == "menkh-job-report-v1" {
                let r=try decoder.decode(FindingReport.self,from:data)
                guard r.voxel_mm==history.voxel_mm,r.origin_mm==(history.origin_mm ?? [0,0,0]),r.remaining_occupied==history.final_occupied,r.operations.map({$0.id})==history.frames.map({$0.stage}) else {throw MeshError.invalidOBJ("Report does not match history")}
                if history.live_sequence != nil {guard r.first_operation==operationOffset else {throw MeshError.invalidOBJ("Finding range mismatch")}}
                for (i,op) in r.operations.enumerated() {
                    for (name,c) in [("Shank / stock",op.shank_stock),("Holder / stock",op.holder_stock),("Shank / fixture",op.shank_fixture),("Holder / fixture",op.holder_fixture),("Cutter / fixture",op.cutter_fixture)] {
                        let contact=c.occupied_centers>0
                        guard contact || c.clearance=="unresolved_voxel_contact" else {continue}
                        guard let bounds=contact ? c.region:c.first_unresolved_cell_bounds, bounds.valid else {throw MeshError.invalidOBJ("Missing contact bounds")}
                        findings.append(Finding(title:"Operation \(operationOffset+i+1) · \(op.id) · \(name) · \(contact ? "contact":"unresolved")",detail:contact ? "\(c.occupied_centers) occupied centers along sweep; assembly shown at segment end; stock checks use pre-operation stock":"Possible voxel face/corner contact; first unresolved cell shown",bounds:bounds,frame:i+1))
                    }
                }
            }
        }
        return findings
    }
    func focusFinding(_ f:Finding) throws {
        try seek(f.frame ?? history.frames.count)
        let b=f.bounds
        let lo=SIMD3(b.lo[0],b.lo[1],b.lo[2]);let hi=SIMD3(b.hi[0],b.hi[1],b.hi[2])
        target=(lo+hi)/2
        distance=max(history.voxel_mm*16,simd_length(hi-lo)*2)
        // A tiny contact cell needs assembly context; otherwise the camera can
        // end up inside the fixture or show only a featureless patch of its face.
        if let index=f.frame, index>0 {
            let step=history.frames[index-1]
            let radius=max(step.cutter?.radius ?? 0,max(step.shank?.radius ?? 0,step.holder?.radius ?? 0))
            distance=max(distance,radius*4)
        }
        sectionAxis=2
        sectionFraction=max(0.000001,min(1,(target.z-origin.z)/(Float(history.grid[2])*history.voxel_mm)))
        compareTarget=f.frame==nil
        showStock=true;showFixtures=true;showHolder=f.frame != nil
        picked="\(f.title) · \(f.detail) · center (\(target.x), \(target.y), \(target.z)) mm"
    }
}
