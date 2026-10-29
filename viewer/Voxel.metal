#include <metal_stdlib>
using namespace metal;
struct Uniforms {
    float4 eye, forward, right, up, low, high, settings;
    uint4 grid;
};
struct Hit { bool found; float t; float3 normal; int3 cell; };
bool filled(int3 p,device const uint *blocks,device const uint *pool,uint n,uint nb) {
    if(any(p<0)||any(p>=int(n)))return false;
    uint3 b=uint3(p)>>3;uint d=blocks[(b.z*nb+b.y)*nb+b.x];
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
    for(uint iter=0;iter<3*u.grid.y+8 && t<=leave;iter++) {
        float3 pos=eye+ray*(t+epsilon);int3 cell=int3(floor(pos));
        if(any(cell<0)||any(cell>=int(u.grid.y)))break;
        uint3 block=uint3(cell)>>3;uint d=blocks[(block.z*u.grid.x+block.y)*u.grid.x+block.x];
        if(d!=0xffffffffu && (d==0xfffffffeu || filled(cell,blocks,pool,u.grid.y,u.grid.x))) {
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
float3 shade(float2 pixel,constant Uniforms &u,device const uint *blocks,device const uint *pool) {
    float2 uv=(pixel/u.settings.yz)*2-1;uv.y=-uv.y;uv.x*=u.settings.y/u.settings.z;
    float3 ray=normalize(u.forward.xyz+u.settings.w*(uv.x*u.right.xyz+uv.y*u.up.xyz));
    Hit hit=trace(u.eye.xyz,ray,u,blocks,pool);
    float3 background=u.grid.z==0?float3(0.83,0.47,0.25):float3(0.055,0.07,0.095);
    if(!hit.found)return background;
    float3 normal=hit.normal;
    // Optional shading-only occupancy gradient; hit position/visibility ALWAYS remain voxel-exact.
    if(u.grid.w!=0) {
        float3 gradient=float3(0);
        for(int z=-2;z<=2;z++)for(int y=-2;y<=2;y++)for(int x=-2;x<=2;x++) {
            int3 d=int3(x,y,z);if(filled(hit.cell+d,blocks,pool,u.grid.y,u.grid.x))gradient-=float3(d);
        }
        if(dot(gradient,gradient)>0.01)normal=normalize(gradient);
    }
    float3 key=normalize(float3(-0.4,-0.55,0.8));
    float diffuse=max(0.0f,dot(normal,key));float fill=max(0.0f,dot(normal,-u.forward.xyz));
    float3 blue=float3(0.32,0.50,0.82);
    float light=0.46+0.32*diffuse+0.22*fill;
    float spec=pow(max(0.0f,dot(normal,normalize(key-ray))),48.0f)*0.10f;
    return blue*light+spec;
}
kernel void voxelImage(texture2d<float,access::write> image [[texture(0)]],device const uint *blocks [[buffer(0)]],device const uint *pool [[buffer(1)]],constant Uniforms &u [[buffer(2)]],uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=image.get_width()||pixel.y>=image.get_height())return;
    float3 color=(shade(float2(pixel)+float2(0.25,0.25),u,blocks,pool)+shade(float2(pixel)+float2(0.75,0.25),u,blocks,pool)+shade(float2(pixel)+float2(0.25,0.75),u,blocks,pool)+shade(float2(pixel)+float2(0.75,0.75),u,blocks,pool))*0.25f;
    image.write(float4(color,1),pixel);
}
