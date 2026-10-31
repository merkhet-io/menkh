#!/usr/bin/env python3
"""A continuous ball-end raster job for live inspection (no physical feed claims)."""
import argparse, json, math
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/live-demo-job.json'));p.add_argument('--voxel',type=float,default=.025);args=p.parse_args()
bounds=dict(lo=[-12,-9,0],hi=[12,9,8])
job=dict(version=1,units='mm',bounds=bounds,voxel_mm=args.voxel,stock=dict(primitives=[dict(box=bounds)]),tools=[dict(cutter=dict(kind='ball',radius=1.5,length=5))],motion_tolerance_mm=.005,export_mesh=False,operations=[],live_inspection=dict(history_operations=32,publish_every_operations=8,min_publish_ms=100))
position=[-9,-6,4]
for row in range(41):
 for col in range(61):
  x=-9+18*(col if row%2==0 else 60-col)/60;y=-6+12*row/40
  end=[x,y,3+.8*math.sin(x*.3)*math.cos(y*.25)]
  job['operations'].append(dict(id=f'row-{row:02}-step-{col:02}',tool=0,line=dict(a=dict(position=position),b=dict(position=end))))
  position=end
args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(job,indent=2)+'\n')
print(f'{args.out}: {len(job["operations"])} continuous ball-end segments, {args.voxel} mm voxels')
