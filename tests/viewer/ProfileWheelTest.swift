import Foundation
import Metal
import simd

func require(_ condition:Bool,_ message:String) throws {if !condition {throw NSError(domain:message,code:1)}}
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {
    print("SKIP: profile-wheel ray tests require Metal hardware");exit(0)
}
let source=try String(contentsOfFile:"viewer/Voxel.metal",encoding:.utf8)+"""

kernel void profileProbe(device const float4 *rays [[buffer(0)]],device float4 *results [[buffer(1)]],constant float4 *pose [[buffer(2)]],constant float2 *profile [[buffer(3)]],constant uint &count [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    Hit h=profileHit(rays[2*i].xyz,rays[2*i+1].xyz,pose[0],pose[1],profile,count);
    results[i]=float4(h.found?h.t:-1.0f,h.normal);
}
"""
let options=MTLCompileOptions();options.mathMode = .safe
let library=try device.makeLibrary(source:source,options:options)
let pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"profileProbe")!)
typealias V=SIMD3<Float>
struct Case {let eye:V;let direction:V;let t:Float}
let crown:[SIMD2<Float>]=[.init(0,1),.init(0.8,2),.init(1.2,2),.init(2,1)]
let waist:[SIMD2<Float>]=[.init(0,2),.init(1,0.5),.init(2,2)]
let cylinder:[SIMD2<Float>]=[.init(0,2),.init(2,2)]
let cases:[([SIMD2<Float>],[Case])]=[
    (crown,[.init(eye:V(3,0,1),direction:V(-1,0,0),t:1),.init(eye:V(3,0,0.4),direction:V(-1,0,0),t:1.5),.init(eye:V(0,0,4),direction:V(0,0,-1),t:2),.init(eye:V(0,0,-2),direction:V(0,0,1),t:2),.init(eye:V(3,0,4),direction:V(0,0,-1),t:-1),.init(eye:V(1.5,0,4),direction:V(0,0,-1),t:2.4),.init(eye:V(3,0,-1),direction:simd_normalize(V(-1.25,0,1)),t:1.3*sqrt(1+1.25*1.25))]),
    (waist,[.init(eye:V(3,0,1),direction:V(-1,0,0),t:2.5),.init(eye:V(3,0,0.5),direction:V(-1,0,0),t:1.75)]),
    (cylinder,[.init(eye:V(2,-3,1),direction:V(0,1,0),t:3),.init(eye:V(0,0,1),direction:V(1,0,0),t:2)])]
var checked=0
for (points,cases) in cases {for rotate in [false,true] {for scale:Float in [1,40] {
    func rotation(_ v:V)->V {rotate ? V(v.z,v.x,v.y):v}
    let base=V(3,-2,5)*scale,axis=rotation(V(0,0,1))
    let rays=cases.flatMap {[SIMD4<Float>(base+rotation($0.eye)*scale,0),SIMD4<Float>(rotation($0.direction),0)]}
    let profile=points.map {$0*scale}
    let pose=[SIMD4<Float>(base,2*scale),SIMD4<Float>(axis,2*scale)]
    let input=rays.withUnsafeBytes {device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
    let output=device.makeBuffer(length:cases.count*16,options:.storageModeShared)!
    let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline);encoder.setBuffer(input,offset:0,index:0);encoder.setBuffer(output,offset:0,index:1)
    pose.withUnsafeBytes {encoder.setBytes($0.baseAddress!,length:$0.count,index:2)}
    profile.withUnsafeBytes {encoder.setBytes($0.baseAddress!,length:$0.count,index:3)}
    var count=UInt32(points.count);encoder.setBytes(&count,length:4,index:4)
    encoder.dispatchThreads(MTLSize(width:cases.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
    try require(command.status == .completed,"GPU profile probe failed")
    let results=output.contents().assumingMemoryBound(to:SIMD4<Float>.self)
    for (i,c) in cases.enumerated() {
        let expected=c.t<0 ? -1:c.t*scale,actual=results[i].x
        try require(abs(actual-expected)<0.0001*max(1,scale),"Profile ray mismatch: expected \(expected), got \(actual), case \(i)")
        if actual>=0 {try require(abs(simd_length(V(results[i].y,results[i].z,results[i].w))-1)<0.0001,"Non-unit wheel normal")}
        checked+=1
    }
}}}
print("Metal wheel profile: \(checked) independent cap/side/waist/tangent/inside/rotated/scaled ray cases passed")
