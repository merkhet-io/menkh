#!/usr/bin/env python3
"""3D transformed cell-union meshes: scanline vs scalar and independent inverse transforms."""
import importlib.util, itertools, json, math, pathlib, struct, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
suite = load('benchmark-engine'); check = load('finishing-inspect')
out = ROOT/'out/scanline-tests'; out.mkdir(parents=True, exist_ok=True)

def rotate(p, angles):
    x,y,z = p
    for axis,a in enumerate(angles):
        c,s = math.cos(a),math.sin(a)
        if axis==0: y,z = c*y-s*z,s*y+c*z
        elif axis==1: x,z = c*x+s*z,-s*x+c*z
        else: x,y = c*x-s*y,s*x+c*y
    return x,y,z

def inverse(p, angles):
    # Transpose of the independently assembled orthonormal basis.
    basis = [rotate([int(i==j) for i in range(3)], angles) for j in range(3)]
    return [sum(p[i]*v[i] for i in range(3)) for v in basis]

cases = {
    'cavity': set(itertools.product(range(3), repeat=3))-{(1,1,1)},
    'concave': {(x,y,z) for x,y,z in itertools.product(range(3),repeat=3) if x==0 or y==0},
    'stacked-disconnected': {(0,0,0),(0,0,3)},
    'thin': {(0,y,z) for y in range(3) for z in range(3)},
}
results=[]
for name,cells in cases.items():
    for variant,angles in enumerate([(0,0,0),(.31,.57,.19),(math.pi/2-1e-8,.13,.71),(math.pi/2-1e-8,0,0)]):
        label=f'{name}-{variant}'; path=out/(label+'.stl');suite.stl_fixture(path,cells)
        data=bytearray(path.read_bytes()); count=struct.unpack_from('<I',data,80)[0]
        thin=.125 if name=='thin' else 1
        for i in range(count):
            for v in range(3):
                off=84+i*50+12+v*12;p=struct.unpack_from('<3f',data,off)
                q=rotate(((p[0]-1.5)*thin,p[1]-1.5,p[2]-1.5),angles)
                struct.pack_into('<3f',data,off,*[q[j]+2 for j in range(3)])
        path.write_bytes(data)
        scale=.001 if variant==1 else 1
        origin=[10000.013,-9999.983,.009] if variant>=2 else [.013,-.017,.009]
        job=suite.job();job.update(export_mesh=False,voxel_mm=.25*scale,
            bounds=dict(lo=[v-scale for v in origin],hi=[v+6*scale for v in origin]),
            stock=dict(stl=dict(path=str(path),unit_scale_mm=scale,translation=origin)))
        jobfile=out/(label+'.json');jobfile.write_text(json.dumps(job))
        outcomes=[]
        for reference in [False,True]:
            dest=out/(label+('-reference' if reference else '-fast'))
            run=subprocess.run([str(suite.EXE),'job',str(jobfile),'--out',str(dest)]+(['--reference'] if reference else []),capture_output=True,text=True)
            outcomes.append(run)
            with (out/'run.log').open('a') as log: log.write(run.stdout+run.stderr)
        if any(r.returncode for r in outcomes):
            assert label in {'cavity-2','concave-2','thin-2'}, ('unexpected parser rejection',label)
            assert all(r.returncode and 'SelfIntersectingSTL' in r.stderr for r in outcomes), label
            results.append(dict(case=label,restricted='SelfIntersectingSTL in both optimized and reference parsing'))
            continue
        fast=out/(label+'-fast');state=check.accuracy.State(fast/'final.menkh')
        assert check.digest(fast/'final.menkh')==check.digest(out/(label+'-reference/final.menkh'))
        checked=skipped=0
        for z,y,x in itertools.product(*(range(n) for n in state.n[::-1])):
            p=[(state.origin[j]+(i+.5)*state.h-origin[j])/scale-2 for j,i in enumerate((x,y,z))]
            q=inverse(p,angles);q=[q[0]/thin+1.5,q[1]+1.5,q[2]+1.5]
            # Exclude only a documented narrow band around ideal cell planes:
            # transformed binary-STL f32 vertices differ from the analytic cells.
            if any(abs(v-round(v))<1e-5 for v in q):skipped+=1;continue
            expected=any(all(c[j]<=q[j]<=c[j]+1 for j in range(3)) for c in cells)
            assert state.occupied(x,y,z)==expected,(label,x,y,z,q)
            checked+=1
        timing=json.loads((fast/'report.json').read_text())['timing']['stock_input']
        results.append(dict(case=label,voxel_exact=True,independent_centers=checked,
                            ideal_plane_band_excluded=skipped,scanlines=timing['scanlines'],fallbacks=timing['scanline_fallbacks']))
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(f'{sum("voxel_exact" in r for r in results)} transformed meshes validated; {sum("restricted" in r for r in results)} existing parser restrictions recorded')
