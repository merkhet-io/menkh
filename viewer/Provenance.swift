import Foundation
import Metal

private struct ProvenanceOperation:Decodable {let id:String;let tool:UInt32?}
private struct ProvenanceHeader:Decodable {
    let format:String;let scope:String;let grid:[Int];let origin_mm:[Float];let voxel_mm:Float
    let final_occupied:UInt64;let entries:Int;let bytes:Int;let record_bytes:Int;let initial_id:Int
    let operations:[ProvenanceOperation]
}
extension VoxelRenderer {
    func loadProvenance() throws {
        let path=root.appendingPathComponent("surface-provenance.json")
        guard FileManager.default.fileExists(atPath:path.path) else {return}
        let p=try JSONDecoder().decode(ProvenanceHeader.self,from:Data(contentsOf:path))
        guard p.format=="menkh-surface-provenance-v1",p.scope=="final_surface",p.grid==history.grid,p.origin_mm==(history.origin_mm ?? [0,0,0]),p.voxel_mm==history.voxel_mm,p.final_occupied==history.final_occupied,p.operations.map({$0.id})==history.frames.map({$0.stage}),p.record_bytes==16,p.initial_id==0,p.entries>=0,p.entries<=67108864,p.bytes==p.entries*16 else {throw MeshError.invalidOBJ("Provenance does not match history")}
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
                guard key<UInt64(history.grid.reduce(1,*)),previous==nil || key>previous!,op>0,Int(op)<=p.operations.count else {throw MeshError.invalidOBJ("Invalid provenance entry")}
                let expected=p.operations[Int(op)-1].tool
                guard expected != UInt32.max,tool==(expected.map {$0+1} ?? 0) else {throw MeshError.invalidOBJ("Provenance tool mismatch")}
                previous=key
            }
        }
        guard let buffer=device.makeBuffer(length:max(16,data.count),options:.storageModeShared) else {throw MeshError.noMetal}
        data.copyBytes(to:buffer.contents().assumingMemoryBound(to:UInt8.self),count:data.count)
        provenanceBuffer=buffer;provenanceCount=UInt32(p.entries)
    }
    func provenanceAt(_ cell:[Int]) -> (UInt32,UInt32)? {
        guard frame==history.frames.count,let buffer=provenanceBuffer,!(0..<3).contains(where:{cell[$0]<0 || cell[$0]>=history.grid[$0]}) else {return nil}
        let key=UInt64((cell[2]*history.grid[1]+cell[1])*history.grid[0]+cell[0])
        var lo=0,hi=Int(provenanceCount)
        while lo<hi {let mid=(lo+hi)/2;let value=buffer.contents().load(fromByteOffset:mid*16,as:UInt64.self);if value<key {lo=mid+1}else{hi=mid}}
        if lo<Int(provenanceCount),buffer.contents().load(fromByteOffset:lo*16,as:UInt64.self)==key {
            return (buffer.contents().load(fromByteOffset:lo*16+8,as:UInt32.self),buffer.contents().load(fromByteOffset:lo*16+12,as:UInt32.self))
        }
        return nil
    }
}
