#!/usr/bin/env python3
"""Independent lower-envelope and bidirectional sampled XZ contour checks.
No engine distance/contains code is imported. Distances are between samples, not Hausdorff bounds.
"""
import argparse, json, math, pathlib, struct, subprocess

def lower(x,y,a,b,r=1):
    # Minimize sphere lower intersection height along the continuous centerline.
    dx,dy,dz=[b[i]-a[i] for i in range(3)];qx=x-a[0];qy=y-a[1]
    vv=dx*dx+dy*dy
    if vv==0:return a[2]+r-math.sqrt(max(0,r*r-qx*qx-qy*qy)) if qx*qx+qy*qy<=r*r else math.inf
    t0=(qx*dx+qy*dy)/vv;perp=qx*qx+qy*qy-t0*t0*vv
    if perp>r*r:return math.inf
    w=math.sqrt(max(0,(r*r-perp)/vv));lo=max(0,t0-w);hi=min(1,t0+w)
    if lo>hi:return math.inf
    # Derivative dz + vv*(t-t0)/sqrt(R²-perp-vv*(t-t0)²)=0.
    t=min(hi,max(lo,t0-dz*math.sqrt(max(0,r*r-perp)/(vv*(vv+dz*dz)))))
    return a[2]+t*dz+r-math.sqrt(max(0,r*r-(qx-t*dx)**2-(qy-t*dy)**2))
class State:
    def __init__(self,path):
        self.data=path.read_bytes();self.origin=struct.unpack_from('<3d',self.data,8);self.size=struct.unpack_from('<3d',self.data,32);self.h=struct.unpack_from('<d',self.data,56)[0]
        self.n=[round(s/self.h) for s in self.size];self.nb=[(n+7)//8 for n in self.n];self.blocks,self.slots=struct.unpack_from('<QQ',self.data,64);self.pool=96+4*self.blocks
    def occupied(self,x,y,z):
        if min(x,y,z)<0 or any(i>=n for i,n in zip((x,y,z),self.n)):return False
        index=((z//8)*self.nb[1]+y//8)*self.nb[0]+x//8;d=struct.unpack_from('<I',self.data,96+4*index)[0]
        if d==0xffffffff:return False
        if d==0xfffffffe:return True
        word=struct.unpack_from('<Q',self.data,self.pool+d*64+(z%8)*8)[0]
        return bool(word & (1<<((y%8)*8+x%8)))
    def top(self,x,y):
        lo,hi=0,self.n[2]
        while lo<hi:
            mid=(lo+hi)//2
            if self.occupied(x,y,mid):lo=mid+1
            else:hi=mid
        return self.origin[2]+lo*self.h

def profile(s,y):
    iy=min(s.n[1]-1,max(0,int((y-s.origin[1])/s.h)));yc=s.origin[1]+(iy+.5)*s.h
    heights=[s.top(x,iy) for x in range(s.n[0])]
    # Sample top edges and every exposed vertical step at voxel edge midpoints.
    points=[]
    for x,z in enumerate(heights):
        points.append((s.origin[0]+(x+.5)*s.h,z))
        if x:
            prev=heights[x-1];n=round(abs(z-prev)/s.h)
            points.extend((s.origin[0]+x*s.h,min(z,prev)+(k+.5)*s.h) for k in range(n))
    return yc,points

def directed(a,b):
    # Section sets are small (hundreds/thousands of points); independent exhaustive NN.
    d=[math.sqrt(min((x-u)**2+(z-v)**2 for u,v in b)) for x,z in a]
    return dict(samples=len(d),max_mm=max(d),mean_mm=sum(d)/len(d))
def run(exe,out):
    out.mkdir(parents=True,exist_ok=True);records=[]
    origin=[.013,-.017,.009];a=[1.113,2.071,2.137];b=[7.113,2.071,5.137];c=[1.113,4.071,3.137];d=[7.113,4.071,3.137]
    for h in [.25,.1,.05,.025]:
        for tol in [.005,.001]:
            job=dict(version=1,units='mm',bounds=dict(lo=origin,hi=[8.013,5.983,6.009]),voxel_mm=h,stock=dict(primitives=[dict(box=dict(lo=origin,hi=[8.013,5.983,6.009]))]),tools=[dict(cutter=dict(kind='ball',radius=1,length=5))],motion_tolerance_mm=tol,export_mesh=False,operations=[dict(id='inclined',tool=0,line=dict(a=dict(position=a),b=dict(position=b))),dict(id='flat',tool=0,line=dict(a=dict(position=c),b=dict(position=d)))])
            folder=out/f'{h}-{tol}';jobfile=out/'job.json';jobfile.write_text(json.dumps(job))
            with (out/'run.log').open('a') as f:subprocess.run([str(exe),'job',str(jobfile),'--out',str(folder)],stdout=f,stderr=f,check=True)
            s=State(folder/'final.menkh');sections=[]
            for y in [2.071,4.071]:
                yc,actual=profile(s,y)
                # Independent exact lower envelope sampled every 0.01 mm plus jump faces.
                ideal=[];previous=None
                for i in range(801):
                    x=origin[0]+8*i/800;z=min(6.009,lower(x,yc,a,b),lower(x,yc,c,d));ideal.append((x,z))
                    if previous and abs(z-previous[1])>.1:
                        n=max(1,math.ceil(abs(z-previous[1])/.01));ideal.extend((x,min(z,previous[1])+(k+.5)*abs(z-previous[1])/n) for k in range(n))
                    previous=(x,z)
                # Uniformly subsample densely represented raster edges for bounded analysis cost.
                actual=actual[::max(1,len(actual)//1600)]
                sections.append(dict(y_mm=yc,raster_to_ideal=directed(actual,ideal),ideal_to_raster=directed(ideal,actual)))
                (folder/f'contour-{y}.json').write_text(json.dumps(dict(raster=actual,continuous=ideal)))
            records.append(dict(voxel_mm=h,motion_tolerance_mm=tol,sections=sections,note='Bidirectional sampled XZ contour distances, not certified Hausdorff; ideal sampling 0.01 mm including jump faces. No STL input in fixture A.'))
            (out/'accuracy.json').write_text(json.dumps(records,indent=2));print(h,tol,'validated',flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--exe',type=pathlib.Path,default=pathlib.Path('zig-out/bin/menkh'));p.add_argument('--out',type=pathlib.Path,default=pathlib.Path('out/finishing/accuracy'));args=p.parse_args();run(args.exe,args.out)
