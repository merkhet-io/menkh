#!/usr/bin/env python3
"""Independent continuous sphere/axial-interval oracle for the COMPLETE ball cutter."""
import argparse, importlib.util, itertools, json, math, pathlib, random, subprocess, hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
inspection=load('finishing-inspect')

def axial(interval,z,v,low,high):
    if interval is None:return None
    if v==0:return interval if low<=z<=high else None
    a,b=sorted(((z-high)/v,(z-low)/v));lo,hi=max(interval[0],a),min(interval[1],b)
    return (lo,hi) if lo<=hi else None

def quadratic(interval,q,v,r):
    if interval is None:return None
    a=sum(x*x for x in v);b=-2*sum(x*y for x,y in zip(q,v));c=sum(x*x for x in q)-r*r
    if a==0:return interval if c<=0 else None
    d=b*b-4*a*c
    if d<0:return None
    root=math.sqrt(d);stable=-.5*(b+math.copysign(root,b))
    roots=(-b/(2*a),)*2 if stable==0 else (stable/a,c/stable)
    lo=max(interval[0],min(roots));hi=min(interval[1],max(roots))
    return (lo,hi) if lo<=hi else None

def continuous(p,a,b,r,length,inflate=0):
    q=[p[i]-a[i] for i in range(3)];v=[b[i]-a[i] for i in range(3)]
    # Lower hemisphere: moving sphere intersected with the moving axial halfspace.
    hemisphere=axial((0,1),q[2],v[2],-math.inf,r+inflate)
    hemisphere=quadratic(hemisphere,[q[0],q[1],q[2]-r],v,r+inflate)
    # Finite cylindrical flute; a sphere-only model fails these cases.
    flute=axial((0,1),q[2],v[2],r-inflate,length+inflate)
    flute=quadratic(flute,q[:2],v[:2],r+inflate)
    return hemisphere is not None or flute is not None

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--smoke',action='store_true');parser.add_argument('--out',type=pathlib.Path,default=ROOT/'out/ball-oracle');args=parser.parse_args()
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);exe=ROOT/'zig-out/bin/menkh'
    origin=[.013,-.017,.009];r=.31;length=1.1
    cases={'stationary':([.8,.9,.3],[.8,.9,.3]),'diagonal':([-.2,.3,.2],[1.6,1.5,.7]),
           'axial':([.8,.9,-.3],[.8,.9,.8]),'tiny':([.8,.9,.3],[.80000001,.9,.3]),
           'reversed':([1.6,1.5,.7],[-.2,.3,.2])}
    configs=[(name,h,.005) for h in ([.25,.1] if args.smoke else [.25,.1,.05,.025]) for name in cases]
    configs.append(('diagonal',.1 if args.smoke else .025,.001));records=[]
    for name,h,tol in configs:
        a,b=[[v+origin[i] for i,v in enumerate(q)] for q in cases[name]]
        label=f'{name}-{h}-{tol}';bounds=dict(lo=origin,hi=[v+2 for v in origin])
        job=dict(version=1,units='mm',bounds=bounds,voxel_mm=h,stock=dict(primitives=[dict(box=bounds)]),
                 tools=[dict(cutter=dict(kind='ball',radius=r,length=length))],motion_tolerance_mm=tol,export_mesh=False,
                 operations=[dict(id=name,tool=0,line=dict(a=dict(position=a),b=dict(position=b)))])
        path=out/(label+'.json');path.write_text(json.dumps(job))
        for ref in [False,True]:
            dest=out/(label+('-reference' if ref else '-fast'))
            with (out/'run.log').open('a') as log:subprocess.run([str(exe),'job',str(path),'--out',str(dest)]+(['--reference'] if ref else []),stdout=log,stderr=log,check=True)
        dest=out/(label+'-fast');assert inspection.digest(dest/'final.menkh')==inspection.digest(out/(label+'-reference/final.menkh'))
        state=inspection.accuracy.State(dest/'final.menkh');n=state.n[0];total=n**3
        indices=range(total) if total<=8000 else random.Random(5729).sample(range(total),10000)
        exact=extra=0;distance=math.dist(a,b);poses=max(1,math.ceil(distance/(2*tol)));dilation=distance/(2*poses)
        for index in indices:
            x=index%n;y=index//n%n;z=index//(n*n);p=[origin[i]+(v+.5)*h for i,v in enumerate((x,y,z))]
            truth=continuous(p,a,b,r,length);removed=not state.occupied(x,y,z)
            assert not truth or removed,('missed continuous engagement',label,p)
            assert not removed or continuous(p,a,b,r,length,dilation+2e-9),('outside expanded-component envelope',label,p)
            exact+=truth;extra+=removed and not truth
        report=json.loads((dest/'report.json').read_text());records.append(dict(case=name,voxel_mm=h,motion_tolerance_mm=tol,
            inspected_centers=len(indices),all_centers_inspected=total<=8000,continuous_engagement_samples=exact,
            conservative_only_samples=extra,missed_continuous_samples=0,outside_component_envelope_samples=0,
            scalar_occupancy_exact=True,removed_voxels=report['operations'][0]['removed_voxels'],motion_bound_mm=dilation))
        print(label,'passed',flush=True)
    summary=dict(records=records,binary_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
        note='Independent continuous quadratic/axial interval oracle; no production distance predicate. Exact continuous containment is checked for all coarse-grid centers and 10000 seeded samples at finer grids. The expanded-component envelope is conservative, not an exact Euclidean offset: it permits up to sqrt(2) times the motion dilation at cylindrical corners. This does not certify a Hausdorff bound or arbitrary tilted tools.')
    (out/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
if __name__=='__main__':main()
