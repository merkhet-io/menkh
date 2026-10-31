import Foundation
import Metal

private struct ProvenanceOperation:Decodable {let id:String;let tool:UInt32?}
private struct ProvenanceHeader:Decodable {
    let format:String;let scope:String;let grid:[Int];let origin_mm:[Float];let voxel_mm:Float
    let final_occupied:UInt64;let entries:Int;let bytes:Int;let record_bytes:Int;let initial_id:Int
    let operations:[ProvenanceOperation]?
    let first_operation:Int?;let completed_operations:Int?;let tool_count:UInt32?
}
extension VoxelRenderer {
    func loadProvenance() throws {
        let path=root.appendingPathComponent("surface-provenance.json")
        guard FileManager.default.fileExists(atPath:path.path) else {return}
        let p=try JSONDecoder().decode(ProvenanceHeader.self,from:Data(contentsOf:path))
        let live=p.format=="menkh-live-provenance-v1"
        guard live || p.format=="menkh-surface-provenance-v1",(p.scope=="final_surface" || p.scope=="all_frames"),p.grid==history.grid,p.origin_mm==(history.origin_mm ?? [0,0,0]),p.voxel_mm==history.voxel_mm,p.final_occupied==history.final_occupied,p.record_bytes==16,p.initial_id==0,p.entries>=0,p.entries<=67108864,p.bytes==p.entries*16 else {throw MeshError.invalidOBJ("Provenance does not match history")}
        if live { guard history.live_sequence != nil,p.scope=="all_frames",p.first_operation==operationOffset,p.completed_operations==operationOffset+history.frames.count,p.tool_count != nil else {throw MeshError.invalidOBJ("Live provenance range mismatch")} }
        else {guard p.operations?.map({$0.id})==history.frames.map({$0.stage}) else {throw MeshError.invalidOBJ("Provenance operations mismatch")}}
        let binary=root.appendingPathComponent("surface-provenance.bin")
        guard try binary.resourceValues(forKeys:[.fileSizeKey]).fileSize==p.bytes else {throw MeshError.invalidOBJ("Invalid provenance buffer length")}
        let data=try Data(contentsOf:binary,options:.mappedIfSafe)
        guard data.count==p.bytes else {throw MeshError.invalidOBJ("Invalid provenance buffer length")}
        var previous:UInt64?=nil
        try data.withUnsafeBytes { bytes in
            for i in 0..<p.entries {
                let key=UInt64(littleEndian:bytes.loadUnaligned(fromByteOffset:i*16,as:UInt64.self))
                let op=UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:i*16+8,as:UInt32.self))
                let tool=UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:i*16+12,as:UInt32.self))
                guard key<UInt64(history.grid.reduce(1,*)),previous==nil || key>previous!,op>0,Int(op)<=operationOffset+history.frames.count else {throw MeshError.invalidOBJ("Invalid provenance entry")}
                if live {guard tool<=p.tool_count! else {throw MeshError.invalidOBJ("Invalid live tool ID")}} else {
                let expected=p.operations![Int(op)-1].tool
                guard expected != UInt32.max,tool==(expected.map {$0+1} ?? 0) else {throw MeshError.invalidOBJ("Provenance tool mismatch")}
                }
                previous=key
            }
        }
        guard let buffer=device.makeBuffer(length:max(16,data.count),options:.storageModeShared) else {throw MeshError.noMetal}
        data.copyBytes(to:buffer.contents().assumingMemoryBound(to:UInt8.self),count:data.count)
        provenanceAllFrames=p.scope=="all_frames";provenanceBuffer=buffer;provenanceCount=UInt32(p.entries)
    }
    func comparisonCounts() -> (UInt64,UInt64)? {
        guard let tb=targetBlocks,let tp=targetPool else {return nil}
        var excess:UInt64=0,missing:UInt64=0
        for b in 0..<(blocks.length/4) {
            let bx=b%history.block_grid[0]*8,by=b/history.block_grid[0]%history.block_grid[1]*8,bz=b/(history.block_grid[0]*history.block_grid[1])*8
            let ex=min(8,history.grid[0]-bx),ey=min(8,history.grid[1]-by)
            var xy:UInt64=0;for y in 0..<ey {xy |= ((UInt64(1)<<UInt64(ex))-1)<<UInt64(y*8)}
            let a=blocks.contents().load(fromByteOffset:b*4,as:UInt32.self),t=tb.contents().load(fromByteOffset:b*4,as:UInt32.self)
            for z in 0..<8 {
                let valid:UInt64=bz+z<history.grid[2] ? xy:0
                func word(_ d:UInt32,_ data:MTLBuffer)->UInt64 {d==0xffffffff ? 0:d==0xfffffffe ? valid:data.contents().load(fromByteOffset:Int(d)*64+z*8,as:UInt64.self)}
                let own=word(a,pool),wanted=word(t,tp);excess+=UInt64((own & ~wanted).nonzeroBitCount);missing+=UInt64((wanted & ~own).nonzeroBitCount)
            }
        }
        return (excess,missing)
    }
    func verifyProvenanceOracle(_ path:URL) throws {
        guard let frames=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [[String:Any]] else {throw MeshError.invalidOBJ("Invalid exposure oracle")}
        for sequence in [frames,Array(frames.reversed()),frames] {
            for entry in sequence {
                guard let frame=entry["frame"] as? Int,let neighbors=entry["neighbors"] as? [[Int]] else {throw MeshError.invalidOBJ("Invalid exposure oracle frame")}
                try seek(frame)
                if let excess=entry["excess_voxels"] as? Int,let missing=entry["missing_voxels"] as? Int {guard let actual=comparisonCounts(),actual.0==UInt64(excess),actual.1==UInt64(missing) else {throw MeshError.invalidOBJ("Target comparison oracle mismatch")}}
                for row in neighbors {
                    guard row.count==3 else {throw MeshError.invalidOBJ("Invalid exposure oracle row")}
                    let key=row[0],n=history.grid
                    let value=provenanceAt([key%n[0],key/n[0]%n[1],key/(n[0]*n[1])]) ?? (0,0)
                    guard value.0==UInt32(row[1]),value.1==UInt32(row[2]) else {throw MeshError.invalidOBJ("Exposure oracle mismatch at frame \(frame), cell \(key)")}
                }
            }
        }
        print("Exposure oracle validated forward/backward/forward: \(frames.count) frames")
    }
    func provenanceAt(_ cell:[Int]) -> (UInt32,UInt32)? {
        guard provenanceAvailableAtFrame,let buffer=provenanceBuffer,!(0..<3).contains(where:{cell[$0]<0 || cell[$0]>=history.grid[$0]}) else {return nil}
        let b=(cell[2]/8*history.block_grid[1]+cell[1]/8)*history.block_grid[0]+cell[0]/8
        let d=blocks.contents().load(fromByteOffset:b*4,as:UInt32.self)
        if d==0xfffffffe {return nil}
        if d<0xfffffffe {let word=pool.contents().load(fromByteOffset:Int(d)*64+cell[2]%8*8,as:UInt64.self);if word & (UInt64(1)<<UInt64(cell[1]%8*8+cell[0]%8)) != 0 {return nil}}
        let key=UInt64((cell[2]*history.grid[1]+cell[1])*history.grid[0]+cell[0])
        var lo=0,hi=Int(provenanceCount)
        while lo<hi {let mid=(lo+hi)/2;let value=buffer.contents().load(fromByteOffset:mid*16,as:UInt64.self);if value<key {lo=mid+1}else{hi=mid}}
        if lo<Int(provenanceCount),buffer.contents().load(fromByteOffset:lo*16,as:UInt64.self)==key {
            let op=buffer.contents().load(fromByteOffset:lo*16+8,as:UInt32.self)
            return op<=UInt32(operationOffset+frame) ? (op,buffer.contents().load(fromByteOffset:lo*16+12,as:UInt32.self)):nil
        }
        return nil
    }
}
