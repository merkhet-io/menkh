#!/usr/bin/env python3
"""Generate a geometric two-flute wheel experiment, not a production drill design."""
import argparse, json, math
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--out',type=Path,default=Path('out/grinding/job.json'))
p.add_argument('--voxel',type=float,default=.5)
p.add_argument('--segments',type=int,default=40)
p.add_argument('--tolerance',type=float,default=.2)
a=p.parse_args()
if not (math.isfinite(a.voxel) and a.voxel>0 and math.isfinite(a.tolerance) and a.tolerance>0 and 1<=a.segments<=2000):p.error('positive voxel/tolerance and 1..2000 segments required')
def pose(t,flute):
    theta=math.radians(120*t+180*flute)
    return dict(position=[109*math.cos(theta),109*math.sin(theta),15+70*t],a_deg=65+4*math.sin(math.pi*t),c_deg=math.degrees(theta))
# Axis Rz(C)Rx(A) is tangential with an axial component. XYZ is wheel center.
job=dict(version=1,units='mm',bounds=dict(lo=[-12,-12,0],hi=[12,12,100]),voxel_mm=a.voxel,
         stock=dict(primitives=[dict(cylinder=dict(base=[0,0,0],radius=12,length=100))]),
         tools=[dict(cutter=dict(kind='flat',radius=100,length=50))],motion_tolerance_mm=a.tolerance,
         export_mesh=False,export_provenance=True,
         operations=[dict(id=f'flute-{f+1}-{i+1:03}',tool=0,rotary=dict(a=pose(i/a.segments,f),b=pose((i+1)/a.segments,f))) for f in range(2) for i in range(a.segments)])
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(job,indent=2)+'\n')
print(a.out)
