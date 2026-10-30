#!/usr/bin/env python3
"""Reproducible engine suite: warm-up + repeated jobs, exact state comparisons, independent accuracy."""
import argparse, copy, json, math, pathlib, statistics, struct, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
EXE = ROOT / 'zig-out/bin/menkh'

def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + '\n')

def box(lo, hi): return {'box': {'lo': lo, 'hi': hi}}
def job(size=8, h=.25):
    return dict(version=1, units='mm', bounds=dict(lo=[0,0,0], hi=[size]*3), voxel_mm=h,
                stock=dict(primitives=[box([0,0,0],[size]*3)]), tools=[], operations=[], export_mesh=True)
def line(name, a, b, axis=(0,0,1), tool=0):
    return dict(id=name, tool=tool, line=dict(a=dict(position=a,axis=axis),b=dict(position=b,axis=axis)))
def run(j, path, out, ref=False):
    write(path,j)
    p=subprocess.run([str(EXE),'job',str(path),'--out',str(out)]+(['--reference'] if ref else []),capture_output=True,text=True)
    if p.returncode: raise RuntimeError(p.stderr)
    return json.loads((out/'report.json').read_text())
def state(path):
    data=path.read_bytes(); blocks,slots=struct.unpack_from('<QQ',data,64)
    desc=struct.unpack_from(f'<{blocks}I',data,96);pool=data[96+blocks*4:]
    # Bench scenarios use complete blocks. Compare represented bits, not allocation order.
    return [b'\0'*64 if d==0xffffffff else b'\xff'*64 if d==0xfffffffe else pool[d*64:d*64+64] for d in desc]
def mesh_volume(path):
    vs=[];volume=0.0
    for row in path.read_text().splitlines():
        f=row.split()
        if not f: continue
        if f[0]=='v':vs.append(tuple(map(float,f[1:])))
        elif f[0]=='f':
            q=[vs[int(v)-1] for v in f[1:]]
            for b,c in [(q[1],q[2]),(q[2],q[3])]:
                a=q[0];volume+=(a[0]*(b[1]*c[2]-b[2]*c[1])+a[1]*(b[2]*c[0]-b[0]*c[2])+a[2]*(b[0]*c[1]-b[1]*c[0]))/6
    return volume,vs

def closed_mesh(path, h):
    # Subdivide greedy-quad perimeter edges into unit lattice edges to handle T-junctions.
    vertices=[];edges={};counts={}
    for row in path.read_text().splitlines():
        fields=row.split()
        if not fields:continue
        if fields[0]=='v':vertices.append(tuple(round(float(v)/h) for v in fields[1:]))
        if fields[0]=='f':
            face=[vertices[int(v)-1] for v in fields[1:]]
            for a,b in zip(face,face[1:]+face[:1]):
                axes=[i for i in range(3) if a[i]!=b[i]]
                assert len(axes)==1
                axis=axes[0];step=1 if b[axis]>a[axis] else -1;p=list(a)
                while tuple(p)!=b:
                    q=p.copy();q[axis]+=step;first,second=sorted((tuple(p),tuple(q)));key=(first,second)
                    edges[key]=edges.get(key,0)+(1 if tuple(p)==first else -1);counts[key]=counts.get(key,0)+1;p=q
    assert all(v==0 for v in edges.values()),'open or inconsistently oriented mesh boundary'
    return sum(v!=2 for v in counts.values())

def stl_fixture(path, cells, rotate=False):
    triangles=[]
    for x,y,z in cells:
        for axis in range(3):
            u,v=(axis+1)%3,(axis+2)%3
            for positive in (False,True):
                neighbor=[x,y,z];neighbor[axis]+=1 if positive else -1
                if tuple(neighbor) in cells:continue
                p=[x,y,z];p[axis]+=positive
                q=[]
                for du,dv in [(0,0),(1,0),(1,1),(0,1)]:
                    a=p.copy();a[u]+=du;a[v]+=dv
                    if rotate:
                        angle=.37;xx,yy=a[:2];a[0]=xx*math.cos(angle)-yy*math.sin(angle)+2;a[1]=xx*math.sin(angle)+yy*math.cos(angle)+1
                    q.append(a)
                if not positive:q.reverse()
                triangles.extend([(q[0],q[1],q[2]),(q[0],q[2],q[3])])
    data=bytearray(80)+struct.pack('<I',len(triangles))
    for t in triangles:data+=struct.pack('<12fH',0,0,0,*sum((list(v) for v in t),[]),0)
    path.write_bytes(data)

def main():
    global EXE
    parser=argparse.ArgumentParser();parser.add_argument('--exe', default=str(EXE));parser.add_argument('--out',default='out/engine-suite');parser.add_argument('--repeats',type=int,default=3);args=parser.parse_args()
    EXE = pathlib.Path(args.exe).resolve()
    if args.repeats<2:parser.error('at least two measured repetitions')
    out=ROOT/args.out;out.mkdir(parents=True,exist_ok=True)
    scenarios={}
    j=job();j['tools']=[dict(cutter=dict(kind='flat',radius=1.2,length=8))];j['operations']=[line('groove',[2,4,5],[6,4,5])];scenarios['groove']=j
    j=job();j['tools']=[dict(cutter=dict(kind='ball',radius=1,length=5))];j['operations']=[line(f'finish-{i}',[1,1+i,4],[7,1+i,5.7]) for i in range(6)];j['motion_tolerance_mm']=.05;scenarios['ball-finishing']=j
    j=job();j['tools']=[dict(cutter=dict(radius=.7,length=9))];j['operations']=[line(f'pocket-{i}',[1.1,1.1+i*.95,1],[6.9,1.1+i*.95,1]) for i in range(7)];scenarios['deep-thin-wall']=j
    j=job();j['tools']=[dict(cutter=dict(radius=1,length=5))];j['operations']=[line('tilted',[1,1,2],[6,6,4],(.6,0,.8))];scenarios['tilted']=j
    j=copy.deepcopy(scenarios['groove']);j['operations']=[line(f'overlap-{i}',[2,4,5],[6,4,5]) for i in range(200)];scenarios['long-overlap']=j
    j=job(80,.5);j['stock']={'primitives':[{'sphere':dict(center=[40.13,39.7,40.2],radius=3)}]};j['tools']=[dict(cutter=dict(radius=1,length=5))];j['operations']=[line('sparse-cut',[38,40,40],[42,40,40])];scenarios['sparse-world']=j
    cells={(x,y,z) for x in range(3) for y in range(3) for z in range(3) if not (x==y==z==1)}
    stl_fixture(out/'cavity.stl',cells)
    j=job();j['stock']={'stl':dict(path=str(out/'cavity.stl'),unit_scale_mm=1)};scenarios['imported-cavity']=j
    cells={(x,y,z) for x in range(3) for y in range(3) for z in range(2) if x==0 or y==0};stl_fixture(out/'concave-rotated.stl',cells,True)
    j=job();j['stock']={'stl':dict(path=str(out/'concave-rotated.stl'),unit_scale_mm=1)};scenarios['imported-concave-rotated']=j
    j=job();j['stock']={'primitives':[{'cylinder':dict(base=[4,4,0],radius=3,length=8)}]};j['operations']=[dict(id='longitudinal',turning=dict(spindle_origin=[4,4,0],mode='longitudinal',radial_start=2,radial_end=2,axial_start=2,axial_end=6,insert_radial_width=2,insert_axial_width=1)),dict(id='facing',turning=dict(spindle_origin=[4,4,0],mode='facing',radial_start=0,radial_end=3,axial_start=7,axial_end=7,insert_radial_width=.2,insert_axial_width=1))];scenarios['turning-envelope']=j
    j=job();j['tools']=[dict(cutter=dict(kind='bull',radius=.6,length=4,corner=.2))];j['operations']=[dict(id='helix',tool=0,arc=dict(center=[4,4,3],radius=2,start_angle=.17,sweep_angle=2*math.pi,rise=1))];j['motion_tolerance_mm']=.1;scenarios['helix']=j
    results={}
    for name,j in scenarios.items():
        samples={};reference_bits=None
        for reference in (True,False):
            mode='scalar' if reference else 'optimized';runs=[]
            for rep in range(args.repeats+1):
                report=run(j,out/(name+'.json'),out/name/mode,reference)
                bits=state(out/name/mode/'final.menkh')
                if reference_bits is None:reference_bits=bits
                assert bits==reference_bits,(name,'occupancy mismatch')
                volume,_=mesh_volume(out/name/mode/'surface.obj');report['mesh_nonmanifold_unit_edges']=closed_mesh(out/name/mode/'surface.obj',j['voxel_mm']);assert abs(volume-report['remaining_volume_mm3'])<1e-5,(name,volume)
                runs.append(report)
            samples[mode]=runs
        results[name]=samples
        print(name,'validated',flush=True)
    accuracy=[]
    for h in (.25,.1,.05,.025):
        j=job(4.5,h);center=[2.13,2.07,2.19];radius=1.43;j['stock']={'primitives':[{'sphere':dict(center=center,radius=radius)}]}
        report=run(j,out/'accuracy.json',out/f'accuracy-{h}')
        volume,vertices=mesh_volume(out/f'accuracy-{h}'/'surface.obj')
        # Samples at mesh vertices; not a continuous Hausdorff proof.
        deviation=max(abs(math.dist(v,center)-radius) for v in vertices)
        analytic=4/3*math.pi*radius**3
        accuracy.append(dict(voxel_mm=h,occupied=report['remaining_occupied'],volume_mm3=volume,analytic_mm3=analytic,error_mm3=volume-analytic,max_sampled_vertex_deviation_mm=deviation,occupancy_boundary_cell_diagonal_bound_mm=math.sqrt(3)*h/2))
    summary={}
    for name,modes in results.items():
        summary[name]={}
        for mode,runs in modes.items():
            measured=runs[1:];cuts=[sum(op['cut_ns'] for op in r['operations'])/1e6 for r in measured];totals=[r['timing']['total_ns']/1e6 for r in measured]
            summary[name][mode]=dict(cut_ms=dict(min=min(cuts),median=statistics.median(cuts),max=max(cuts)),total_ms=dict(min=min(totals),median=statistics.median(totals),max=max(totals)),grid_bytes=measured[-1]['stats']['descriptor_bytes']+measured[-1]['stats']['pool_bytes'],peak_rss_bytes=max(r['process_peak_rss_bytes'] for r in measured),history_bytes=measured[-1]['history_bytes'])
    write(out/'results.json',dict(warmups=1,repeats=args.repeats,workers=1,zig='0.15.2',mode='ReleaseFast',baseline_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),executable_sha256=__import__('hashlib').sha256(EXE.read_bytes()).hexdigest(),source_fingerprint_scope='Current checkout, not necessarily the supplied --exe binary',source_sha256={str(p.relative_to(ROOT)):__import__('hashlib').sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'src').glob('*.zig'))},raw=results,summary=summary,accuracy=accuracy))
if __name__=='__main__':main()
