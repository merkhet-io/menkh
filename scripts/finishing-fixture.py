#!/usr/bin/env python3
"""Original procedural fixture and example contact-envelope path; protocol v1."""
import argparse, json, math, pathlib, struct
OFFSET = (0.013, -0.017, 0.009)
def height(x,y):
    return (6+.7*math.cos(x/4)*math.cos(y/3)-1.4*math.exp(-((x-8)/3)**2-((y-6)/2)**2)
            -1.1*math.exp(-((x-17)/2.5)**2-((y-11)/2)**2)+.65*math.exp(-((y-8)/.25)**2))
def point(x,y,z):return [x+OFFSET[0],y+OFFSET[1],z+OFFSET[2]]
def mesh(path, allowance):
    nx,ny=192,128
    top=[[point(i*.125,j*.125,height(i*.125,j*.125)+allowance) for i in range(nx+1)] for j in range(ny+1)]
    tris=[]
    for j in range(ny):
        for i in range(nx):
            a,b,c,d=top[j][i],top[j][i+1],top[j+1][i+1],top[j+1][i]
            tris.extend(((a,b,c),(a,c,d)))
    ring=top[0][:-1]+[top[j][nx] for j in range(ny)]+list(reversed(top[ny][1:]))+[top[j][0] for j in range(ny,0,-1)]
    center=point(12,8,0)
    for a,b in zip(ring,ring[1:]+ring[:1]):
        aa=[a[0],a[1],OFFSET[2]];bb=[b[0],b[1],OFFSET[2]]
        tris.extend(((aa,bb,b),(aa,b,a),(center,bb,aa)))
    with path.open('wb') as f:
        f.write(b'Menkh original procedural insert; mm'.ljust(80,b'\0')+struct.pack('<I',len(tris)))
        for t in tris:f.write(struct.pack('<12fH',0,0,0,*sum((list(v) for v in t),[]),0))
def line(i,a,b):return dict(id=f'finish-{i:05}',tool=0,line=dict(a=dict(position=a),b=dict(position=b)))
def generate(out,h):
    out.mkdir(parents=True,exist_ok=True)
    for name,allowance in [('stock',.8),('target',0)]:
        if not (out/(name+'.stl')).exists():mesh(out/(name+'.stl'),allowance)
    disk=[(i*.1,j*.1,math.sqrt(max(0,1-(i*.1)**2-(j*.1)**2))-1) for i in range(-10,11) for j in range(-10,11) if i*i+j*j<=100]
    poses=[]
    for row in range(80):
        y=.1+row*.2
        xs=[i*24/64 for i in range(65)]
        if row%2:xs.reverse()
        for x in xs:
            z=max(height(min(24,max(0,x+dx)),min(16,max(0,y+dy)))+dz for dx,dy,dz in disk)+.03
            poses.append(point(x,y,z))
    job=dict(version=1,units='mm',bounds=dict(lo=list(OFFSET),hi=point(24,16,10)),voxel_mm=h,
        stock=dict(stl=dict(path=str((out/'stock.stl').resolve()),unit_scale_mm=1)),
        target=dict(stl=dict(path=str((out/'target.stl').resolve()),unit_scale_mm=1)),
        tools=[dict(cutter=dict(kind='ball',radius=1,length=5),shank=dict(radius=.8,length=2,offset=5),holder=dict(radius=2,length=2,offset=7))],
        motion_tolerance_mm=.005,export_mesh=False,operations=[line(i,a,b) for i,(a,b) in enumerate(zip(poses,poses[1:]))])
    (out/'job.json').write_text(json.dumps(job,indent=2)+'\n')
    (out/'provenance.json').write_text(json.dumps(dict(generator='scripts/finishing-fixture.py',protocol='v1',license='original project fixture; no third-party assets',triangulation_mm=.125,stock_allowance_mm=.8,max_vertex_coordinate_rounding_mm=max(abs(struct.unpack('<f',struct.pack('<f',v))[0]-v) for i in range(193) for k in range(129) for v in point(i*.125,k*.125,height(i*.125,k*.125)+.8))),indent=2)+'\n')
    print(f'{out}/job.json: {len(job["operations"])} segments, voxel {h} mm')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path,default=pathlib.Path('out/finishing'));p.add_argument('--voxel',type=float,default=.025);a=p.parse_args();generate(a.out,a.voxel)
