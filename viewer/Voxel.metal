#include <metal_stdlib>
using namespace metal;
struct Uniforms {
    float4 eye, forward, right, up, low, high, settings;
    uint4 grid;
    uint4 dimensions,blockDimensions;
    float4 shank,shankAxis,holder,holderAxis,cutter,cutterAxis;
    uint4 provenance;
};
struct Exposure {ulong cell; uint operation,tool;};
struct Hit { bool found; float t; float3 normal; int3 cell; };
bool filled(int3 p,device const uint *blocks,device const uint *pool,uint3 n,uint3 nb) {
    if(any(p<0)||any(p>=int3(n)))return false;
    uint3 b=uint3(p)>>3;uint d=blocks[(b.z*nb.y+b.y)*nb.x+b.x];
    if(d==0xffffffffu)return false;if(d==0xfffffffeu)return true;
    uint bit=uint(p.y&7)*8+uint(p.x&7);return (pool[d*16+uint(p.z&7)*2+(bit>>5)]&(1u<<(bit&31)))!=0;
}
Hit trace(float3 eye,float3 ray,constant Uniforms &u,device const uint *blocks,device const uint *pool) {
    float3 inv=1.0f/select(ray,float3(1e-15f),abs(ray)<1e-15f);
    float3 a=(u.low.xyz-eye)*inv;float3 b=(u.high.xyz-eye)*inv;
    float3 near=min(a,b),far=max(a,b);
    float enter=max(max(near.x,near.y),near.z),leave=min(min(far.x,far.y),far.z);
    Hit hit;hit.found=false;hit.t=0;hit.normal=float3(0,0,1);hit.cell=int3(0);
    if(leave<max(enter,0.0f))return hit;
    uint axis=near.x>near.y?(near.x>near.z?0:2):(near.y>near.z?1:2);
    float3 normal=float3(0);normal[axis]=ray[axis]>0?-1:1;
    float t=max(enter,0.0f);const float epsilon=0.001f;
    // Bound: <= 3*n voxel transitions plus block skips on a finite grid ray.
    for(uint iter=0;iter<u.dimensions.x+u.dimensions.y+u.dimensions.z+8 && t<=leave;iter++) {
        float3 pos=eye+ray*(t+epsilon);int3 cell=int3(floor(pos));
        if(any(cell<0)||any(cell>=int3(u.dimensions.xyz)))break;
        uint3 block=uint3(cell)>>3;uint d=blocks[(block.z*u.blockDimensions.y+block.y)*u.blockDimensions.x+block.x];
        if(d!=0xffffffffu && (d==0xfffffffeu || filled(cell,blocks,pool,u.dimensions.xyz,u.blockDimensions.xyz))) {
            hit.found=true;hit.t=t;hit.normal=normal;hit.cell=cell;return hit;
        }
        int step=d==0xffffffffu?8:1;
        int3 base=(cell/step)*step;
        float3 edge=float3(base)+select(float3(0),float3(step),ray>0);
        float3 next=(edge-eye)*inv;
        axis=next.x<next.y?(next.x<next.z?0:2):(next.y<next.z?1:2);
        float nt=next[axis];
        if(nt<=t)nt=t+epsilon;
        t=nt;normal=float3(0);normal[axis]=ray[axis]>0?-1:1;
    }
    return hit;
}
Hit cylinderHit(float3 eye,float3 ray,float4 part,float4 axial) {
    Hit hit;hit.found=false;hit.t=INFINITY;hit.normal=float3(0,0,1);hit.cell=int3(0);if(part.w<=0 || axial.w<=0)return hit;
    float3 q=eye-part.xyz;float z=dot(q,axial.xyz),vz=dot(ray,axial.xyz);float3 qr=q-axial.xyz*z,vr=ray-axial.xyz*vz;
    float low=0,high=INFINITY;
    if(abs(vz)<1e-10f){if(z<0 || z>axial.w)return hit;}else {float a=-z/vz,b=(axial.w-z)/vz;low=max(low,min(a,b));high=min(high,max(a,b));}
    float a=dot(vr,vr),b=dot(qr,vr),c=dot(qr,qr)-part.w*part.w;
    if(a<1e-12f){if(c>0)return hit;}else {float disc=b*b-a*c;if(disc<0)return hit;float root=sqrt(disc);low=max(low,(-b-root)/a);high=min(high,(-b+root)/a);}
    if(low>high)return hit;hit.found=true;hit.t=low;float3 p=q+low*ray;float h=dot(p,axial.xyz);hit.normal=h<0.002f?-axial.xyz:(h>axial.w-0.002f?axial.xyz:normalize(p-h*axial.xyz));return hit;
}
// Complete ball cutter: lower hemisphere plus finite upper cylindrical flute.
Hit ballHit(float3 eye,float3 ray,float4 part,float4 axial) {
    float4 upper=part;upper.xyz+=axial.xyz*part.w;
    float4 flute=axial;flute.w=max(0.0f,axial.w-part.w);
    Hit hit=cylinderHit(eye,ray,upper,flute);
    if(part.w<=0)return hit;
    float3 q=eye-upper.xyz;float b=dot(q,ray),c=dot(q,q)-part.w*part.w;
    float disc=b*b-c;if(disc<0)return hit;
    float lo=max(0.0f,-b-sqrt(disc)),hi=-b+sqrt(disc);
    float z=dot(q,axial.xyz),v=dot(ray,axial.xyz);
    if(abs(v)<1e-10f){if(z>0)return hit;}
    else if(v>0)hi=min(hi,-z/v);else lo=max(lo,-z/v);
    if(lo<=hi && (!hit.found || lo<hit.t)){hit.found=true;hit.t=lo;float3 p=q+ray*lo;hit.normal=abs(dot(p,axial.xyz))<.001f?axial.xyz:normalize(p);}
    return hit;
}
float3 shade(float2 pixel,constant Uniforms &u,device const uint *blocks,device const uint *pool,device const uint *targetBlocks,device const uint *targetPool,device const uint *fixtureBlocks,device const uint *fixturePool,device const Exposure *exposures) {
    float2 uv=(pixel/u.settings.yz)*2-1;uv.y=-uv.y;uv.x*=u.settings.y/u.settings.z;
    float3 ray=normalize(u.forward.xyz+u.settings.w*(uv.x*u.right.xyz+uv.y*u.up.xyz));
    Hit hit=trace(u.eye.xyz,ray,u,blocks,pool);
    float3 background=u.grid.z==0?float3(0.83,0.47,0.25):float3(0.055,0.07,0.095);
    if(u.grid.x==0)hit.found=false;
    bool missing=false;
    if(u.dimensions.w!=0) {Hit th=trace(u.eye.xyz,ray,u,targetBlocks,targetPool);if(th.found && (!hit.found || th.t<hit.t-0.01f)){hit=th;missing=true;}}
    bool fixture=false;
    if(u.blockDimensions.w!=0){Hit fh=trace(u.eye.xyz,ray,u,fixtureBlocks,fixturePool);if(fh.found && (!hit.found || fh.t<hit.t)){hit=fh;fixture=true;}}
    Hit sh=cylinderHit(u.eye.xyz,ray,u.shank,u.shankAxis),ho=cylinderHit(u.eye.xyz,ray,u.holder,u.holderAxis);
    Hit cutter=u.eye.w!=0?ballHit(u.eye.xyz,ray,u.cutter,u.cutterAxis):cylinderHit(u.eye.xyz,ray,u.cutter,u.cutterAxis);
    Hit part=(sh.found && (!ho.found || sh.t<ho.t))?sh:ho;
    if(cutter.found && (!part.found || cutter.t<part.t))part=cutter;
    if(part.found && (!hit.found || part.t<hit.t))return float3(0.65,0.68,0.72)*(0.45+0.55*max(0.0f,dot(part.normal,normalize(float3(-0.4,-0.55,0.8)))));
    if(!hit.found)return background;
    float3 normal=hit.normal;
    // Optional shading-only occupancy gradient; hit position/visibility ALWAYS remain voxel-exact.
    if(u.grid.w!=0 && !missing && !fixture) {
        float3 gradient=float3(0);
        for(int z=-2;z<=2;z++)for(int y=-2;y<=2;y++)for(int x=-2;x<=2;x++) {
            int3 d=int3(x,y,z);if(filled(hit.cell+d,blocks,pool,u.dimensions.xyz,u.blockDimensions.xyz))gradient-=float3(d);
        }
        if(dot(gradient,gradient)>0.01)normal=normalize(gradient);
    }
    float3 key=normalize(float3(-0.4,-0.55,0.8));
    float diffuse=max(0.0f,dot(normal,key));float fill=max(0.0f,dot(normal,-u.forward.xyz));
    float3 blue=float3(0.32,0.50,0.82);
    if(u.dimensions.w!=0) {if(missing)blue=float3(0.95,0.18,0.15);else if(!filled(hit.cell,targetBlocks,targetPool,u.dimensions.xyz,u.blockDimensions.xyz))blue=float3(0.98,0.8,0.12);}
    if(u.provenance.y!=0 && !fixture && !missing) {
        int3 neighbor=hit.cell+int3(hit.normal);
        uint label=0;
        float3 facePosition=u.eye.xyz+ray*hit.t;
        float coordinate=dot(facePosition,abs(hit.normal));
        if(abs(coordinate-round(coordinate))<0.01f && all(neighbor>=0) && all(neighbor<int3(u.dimensions.xyz)) && !filled(neighbor,blocks,pool,u.dimensions.xyz,u.blockDimensions.xyz)) {
            ulong cell=(ulong(neighbor.z)*u.dimensions.y+uint(neighbor.y))*u.dimensions.x+uint(neighbor.x);
            uint lo=0,hi=u.provenance.x;
            while(lo<hi){uint mid=lo+(hi-lo)/2;if(exposures[mid].cell<cell)lo=mid+1;else hi=mid;}
            if(lo<u.provenance.x && exposures[lo].cell==cell)label=u.provenance.y==1?exposures[lo].operation:exposures[lo].tool;
        }
        uint hash=label*2654435761u;hash^=hash>>16;
        blue=label==0?float3(.58,.6,.63):float3(.25)+float3(float(hash&255u),float((hash>>8)&255u),float((hash>>16)&255u))*(.7/255.0);
    }
    if(fixture)blue=float3(0.25,0.7,0.4);
    float light=0.46+0.32*diffuse+0.22*fill;
    float spec=pow(max(0.0f,dot(normal,normalize(key-ray))),48.0f)*0.10f;
    return blue*light+spec;
}
kernel void voxelImage(texture2d<float,access::write> image [[texture(0)]],device const uint *blocks [[buffer(0)]],device const uint *pool [[buffer(1)]],constant Uniforms &u [[buffer(2)]],device const uint *targetBlocks [[buffer(3)]],device const uint *targetPool [[buffer(4)]],device const uint *fixtureBlocks [[buffer(5)]],device const uint *fixturePool [[buffer(6)]],device const Exposure *exposures [[buffer(7)]],uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=image.get_width()||pixel.y>=image.get_height())return;
    float3 color=(shade(float2(pixel)+float2(0.25,0.25),u,blocks,pool,targetBlocks,targetPool,fixtureBlocks,fixturePool,exposures)+shade(float2(pixel)+float2(0.75,0.25),u,blocks,pool,targetBlocks,targetPool,fixtureBlocks,fixturePool,exposures)+shade(float2(pixel)+float2(0.25,0.75),u,blocks,pool,targetBlocks,targetPool,fixtureBlocks,fixturePool,exposures)+shade(float2(pixel)+float2(0.75,0.75),u,blocks,pool,targetBlocks,targetPool,fixtureBlocks,fixturePool,exposures))*0.25f;
    image.write(float4(color,1),pixel);
}
