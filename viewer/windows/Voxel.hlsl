// Display-only D3D12 ray traversal of binary voxel occupancy. No GPU cutting.
cbuffer Uniforms : register(b0) {
    float4 eye, forward, right, up, low, high, settings;
    uint4 dimensions, blockDimensions, flags;
    float4 shank, shankAxis, holder, holderAxis, cutter, cutterAxis;
};
StructuredBuffer<uint> blocks : register(t0);
StructuredBuffer<uint> pool : register(t1);
RWTexture2D<float4> image : register(u0);
struct Hit { bool found; float t; float3 normal; int3 cell; };
Hit miss() { Hit h;h.found=false;h.t=1e30;h.normal=float3(0,0,1);h.cell=0;return h; }
bool filled(int3 p) {
    if(any(p<0)||any(p>=int3(dimensions.xyz)))return false;
    uint3 b=uint3(p)>>3;uint d=blocks[(b.z*blockDimensions.y+b.y)*blockDimensions.x+b.x];
    if(d==0xffffffffu)return false;if(d==0xfffffffeu)return true;
    uint bit=uint(p.y&7)*8+uint(p.x&7);return (pool[d*16+uint(p.z&7)*2+(bit>>5)]&(1u<<(bit&31)))!=0;
}
Hit trace(float3 ray) {
    float3 safe=float3(abs(ray.x)<1e-15?1e-15:ray.x,abs(ray.y)<1e-15?1e-15:ray.y,abs(ray.z)<1e-15?1e-15:ray.z);
    float3 inv=1/safe,a=(low.xyz-eye.xyz)*inv,b=(high.xyz-eye.xyz)*inv;
    float3 near=min(a,b),far=max(a,b);float enter=max(max(near.x,near.y),near.z),leave=min(min(far.x,far.y),far.z);
    Hit hit=miss();if(leave<max(enter,0))return hit;
    uint axis=near.x>near.y?(near.x>near.z?0:2):(near.y>near.z?1:2);
    float3 normal=0;normal[axis]=ray[axis]>0?-1:1;float t=max(enter,0);const float epsilon=0.001;
    [loop] for(uint iter=0;iter<dimensions.x+dimensions.y+dimensions.z+8 && t<=leave;iter++) {
        int3 cell=int3(floor(eye.xyz+ray*(t+epsilon)));
        if(any(cell<0)||any(cell>=int3(dimensions.xyz)))break;
        uint3 block=uint3(cell)>>3;uint d=blocks[(block.z*blockDimensions.y+block.y)*blockDimensions.x+block.x];
        if(d!=0xffffffffu && (d==0xfffffffeu || filled(cell))) {hit.found=true;hit.t=t;hit.normal=normal;hit.cell=cell;return hit;}
        int stride=d==0xffffffffu?8:1;int3 base=(cell/stride)*stride;
        float3 edge=float3(base)+float3(ray.x>0?stride:0,ray.y>0?stride:0,ray.z>0?stride:0);
        float3 next=(edge-eye.xyz)*inv;axis=next.x<next.y?(next.x<next.z?0:2):(next.y<next.z?1:2);
        float nt=next[axis];if(nt<=t)nt=t+epsilon;t=nt;normal=0;normal[axis]=ray[axis]>0?-1:1;
    }return hit;
}
Hit cylinderHit(float3 ray,float4 part,float4 axial) {
    Hit hit=miss();if(part.w<=0||axial.w<=0)return hit;
    float3 q=eye.xyz-part.xyz;float z=dot(q,axial.xyz),vz=dot(ray,axial.xyz);float3 qr=q-axial.xyz*z,vr=ray-axial.xyz*vz;
    float lower=0,upper=1e30;
    if(abs(vz)<1e-10){if(z<0||z>axial.w)return hit;}else{float a=-z/vz,b=(axial.w-z)/vz;lower=max(lower,min(a,b));upper=min(upper,max(a,b));}
    float a=dot(vr,vr),b=dot(qr,vr),c=dot(qr,qr)-part.w*part.w;
    if(a<1e-12){if(c>0)return hit;}else{float disc=b*b-a*c;if(disc<0)return hit;float root=sqrt(disc);lower=max(lower,(-b-root)/a);upper=min(upper,(-b+root)/a);}
    if(lower>upper)return hit;hit.found=true;hit.t=lower;float3 p=q+lower*ray;float h=dot(p,axial.xyz);hit.normal=h<.002?-axial.xyz:(h>axial.w-.002?axial.xyz:normalize(p-h*axial.xyz));return hit;
}
float3 shade(float2 pixel) {
    float2 uv=pixel/settings.yz*2-1;uv.y=-uv.y;uv.x*=settings.y/settings.z;
    float3 ray=normalize(forward.xyz+settings.w*(uv.x*right.xyz+uv.y*up.xyz));Hit hit=trace(ray);
    float3 bg=flags.x==0?float3(.83,.47,.25):float3(.055,.07,.095);
    Hit part=cylinderHit(ray,cutter,cutterAxis),s=cylinderHit(ray,shank,shankAxis),h=cylinderHit(ray,holder,holderAxis);
    if(s.found&&s.t<part.t)part=s;if(h.found&&h.t<part.t)part=h;
    float3 key=normalize(float3(-.4,-.55,.8));
    if(part.found&&(!hit.found||part.t<hit.t))return float3(.65,.68,.72)*(.45+.55*max(0,dot(part.normal,key)));
    if(!hit.found)return bg;
    float3 normal=hit.normal;
    float light=.46+.32*max(0,dot(normal,key))+.22*max(0,dot(normal,-forward.xyz));
    float spec=pow(max(0,dot(normal,normalize(key-ray))),48)*.10;
    return float3(.32,.50,.82)*light+spec;
}
[numthreads(8,8,1)] void main(uint3 pixel:SV_DispatchThreadID) {
    if(pixel.x>=uint(settings.y)||pixel.y>=uint(settings.z))return;
    float3 color=shade(float2(pixel.xy)+.5);
    if(flags.y!=0)color=(shade(float2(pixel.xy)+float2(.25,.25))+shade(float2(pixel.xy)+float2(.75,.25))+shade(float2(pixel.xy)+float2(.25,.75))+shade(float2(pixel.xy)+float2(.75,.75)))*.25;
    image[pixel.xy]=float4(color,1);
}
