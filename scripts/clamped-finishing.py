#!/usr/bin/env python3
"""Imported insert with safe low clamps and deliberately colliding tall clamps.
Original procedural geometry; no customer geometry or third-party assets.
"""
import argparse, copy, importlib.util, itertools, json, math, pathlib, struct, subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
workflow=load('finishing-workflow');oracle=load('validate-ball-sweep')

def write_boxes(path,boxes):
    triangles=[];rounded=[]
    faces=[(0,2,1),(0,3,2),(4,5,6),(4,6,7),(0,1,5),(0,5,4),(1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
    for lo,hi in boxes:
        lo,hi=[[struct.unpack('<f',struct.pack('<f',x))[0] for x in p] for p in (lo,hi)];rounded.append((lo,hi))
        vertices=[(lo[0],lo[1],lo[2]),(hi[0],lo[1],lo[2]),(hi[0],hi[1],lo[2]),(lo[0],hi[1],lo[2]),
                  (lo[0],lo[1],hi[2]),(hi[0],lo[1],hi[2]),(hi[0],hi[1],hi[2]),(lo[0],hi[1],hi[2])]
        triangles.extend([vertices[i] for i in face] for face in faces)
    data=bytearray(80)+struct.pack('<I',len(triangles))
    for triangle in triangles:data+=struct.pack('<12fH',0,0,0,*[x for p in triangle for x in p],0)
    path.write_bytes(data);return rounded

def independent_count(job,boxes,op,part):
    # Direct finite-cylinder time interval intersection; no engine mask or SDF.
    eps=1e-10;h=job['voxel_mm'];origin=job['bounds']['lo'];a=op['line']['a']['position'];b=op['line']['b']['position']
    a=[a[0],a[1],a[2]+part['offset']];b=[b[0],b[1],b[2]+part['offset']];v=[b[i]-a[i] for i in range(3)];r=part['radius'];length=part['length']
    low=[min(a[0],b[0])-r,min(a[1],b[1])-r,min(a[2],b[2])];high=[max(a[0],b[0])+r,max(a[1],b[1])+r,max(a[2],b[2])+length];count=0
    for blo,bhi in boxes:
        lo=[max(blo[j],low[j]) for j in range(3)];hi=[min(bhi[j],high[j]) for j in range(3)]
        ranges=[range(max(0,math.ceil((lo[j]-origin[j])/h-.5-1e-8)),max(0,math.floor((hi[j]-origin[j])/h-.5+1e-8)+1)) for j in range(3)]
        for x,y,z in itertools.product(*ranges):
            p=[origin[j]+(n+.5)*h for j,n in enumerate((x,y,z))]
            if not all(blo[j]-eps<=p[j]<=bhi[j]+eps for j in range(3)):continue
            q=[p[j]-a[j] for j in range(3)];interval=oracle.axial((0,1),q[2],v[2],-eps,length+eps)
            count+=oracle.quadratic(interval,q[:2],v[:2],r+eps) is not None
    return count

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--voxel',type=float,default=.1);p.add_argument('--out',type=pathlib.Path,default=ROOT/'out/clamped-finishing');p.add_argument('--skip-build',action='store_true');args=p.parse_args()
    if not math.isfinite(args.voxel) or args.voxel<=0:p.error('voxel size must be finite and positive')
    if not args.skip_build:subprocess.run([str(ROOT/'zig'),'build','-Doptimize=ReleaseFast'],cwd=ROOT,check=True)
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);workflow.fixture.generate(out/'fixture',args.voxel)
    original=json.loads((out/'fixture/job.json').read_text());origin=original['bounds']['lo'];records={};material=None;witnesses=[]
    for name,height in [('safe',2),('unsafe',13)]:
        job=copy.deepcopy(original);job['bounds']={'lo':[origin[i]+v for i,v in enumerate((-3,-3,0))], 'hi':[origin[i]+v for i,v in enumerate((27,19,14))]}
        boxes=[([origin[0]-2.5,origin[1]+4,origin[2]],[origin[0]-.1,origin[1]+7,origin[2]+height]),
               ([origin[0]+24.1,origin[1]+9,origin[2]],[origin[0]+26.5,origin[1]+12,origin[2]+height])]
        stl=out/'fixture'/f'{name}-clamps.stl';boxes=write_boxes(stl,boxes);job['fixtures']={'stl':{'path':str(stl),'unit_scale_mm':1}}
        report=workflow.execute(ROOT/'zig-out/bin/menkh',job,out/name);digest=workflow.inspection.digest(out/name/'final.menkh');material=material or digest;assert digest==material
        statuses={}
        for field in ['cutter_fixture','shank_fixture','holder_fixture']:
            status={}
            for op in report['operations']:status[op[field]['clearance']]=status.get(op[field]['clearance'],0)+1
            statuses[field]=status
            if name=='safe':assert status=={'separated_voxel_geometry':len(job['operations'])},(field,status)
            else:assert status.get('occupied_center_contact',0)>0,(field,status)
        if name=='unsafe':
            for part_name in ['shank','holder']:
                field=part_name+'_fixture';hits=[i for i,op in enumerate(report['operations']) if op[field]['occupied_centers']]
                selected=sorted({0,len(job['operations'])//2,len(job['operations'])-1,hits[0],hits[len(hits)//2],hits[-1]})
                for i in selected:
                    expected=independent_count(job,boxes,job['operations'][i],job['tools'][0][part_name]);actual=report['operations'][i][field]['occupied_centers'];assert expected==actual,(part_name,i,expected,actual)
                    witnesses.append(dict(operation=job['operations'][i]['id'],part=part_name,independent_center_count=expected,reported_center_count=actual))
        records[name]=dict(wall_s=report['wall_s'],peak_rss_bytes=report['process_peak_rss_bytes'],fixture_status_counts=statuses,
                           occupancy_sha256=digest,remaining_voxels=report['remaining_occupied'],voxel_mm=args.voxel)
        print(name,statuses,flush=True)
    workflow.write(out/'summary.json',dict(runs=records,independent_flat_assembly_checks=witnesses,
        note='Procedural representative clamping setup, not customer-qualified CAM. Unsafe tall clamps deliberately intersect the tool assembly. Collisions are reported; they do not abort or alter material subtraction. Separation applies to represented voxel cubes against the conservative sweep, not real-world clearance.'))
if __name__=='__main__':main()
