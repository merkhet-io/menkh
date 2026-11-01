#!/usr/bin/env python3
"""Validate a continuous-ray dump without materializing its volume or a mesh."""
import argparse,json,math,mmap,struct,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('manifest',type=Path);p.add_argument('--check-screw-invariants',action='store_true');a=p.parse_args()
start=time.perf_counter();r=json.loads(a.manifest.read_text())
assert r['format']=='menkh-experimental-z-rays-v1' and r['units']=='mm'
assert Path(r['file']).name==r['file']
cols,spans=r['columns'],r['intervals'];h=r['spacing_mm'];origin=r['origin'];nx,ny=r['grid_xy']
assert type(cols) is int and type(spans) is int and cols>=0 and spans>=0
assert math.isfinite(h) and h>0 and len(origin)==3 and all(math.isfinite(x) for x in origin)
assert type(nx) is int and type(ny) is int and 0<nx<=65536 and 0<ny<=65536
if a.check_screw_invariants: assert origin==[-6,-6,0] and nx==ny==math.ceil(12/h-.5)
expected_offset=0;previous=-1;touching=0;length=0.;correction=0.;core_columns=0
with (a.manifest.parent/r['file']).open('rb') as file:
 assert file.seek(0,2)==cols*24+spans*16, 'Truncated or trailing data'
 if cols==0:
  assert spans==0
 else:
  with mmap.mmap(file.fileno(),0,access=mmap.ACCESS_READ) as data:
   for i in range(cols):
    x,y,offset,count=struct.unpack_from('<IIQQ',data,i*24)
    assert x<nx and y<ny and y*nx+x>previous and offset==expected_offset and offset+count<=spans
    previous=y*nx+x;expected_offset+=count;last=-math.inf;first_span=None;last_span=None
    for j in range(count):
     lo,hi=struct.unpack_from('<dd',data,cols*24+(offset+j)*16)
     assert math.isfinite(lo) and math.isfinite(hi) and lo<hi and lo>=last
     touching+=int(lo==last);last=hi
     if first_span is None:first_span=(lo,hi)
     last_span=(lo,hi)
     value=(hi-lo)-correction;updated=length+value;correction=(updated-length)-value;length=updated
    if a.check_screw_invariants:
     assert first_span and first_span[0]==0 and first_span[1]>=1 and last_span[0]<=39 and last_span[1]==40
     px=-6+(x+.5)*h;py=-6+(y+.5)*h
     if px*px+py*py<3.5**2:
      assert count==1 and first_span==(0.,40.), 'Retained core changed'
      core_columns+=1
assert expected_offset==spans
print(json.dumps(dict(columns=cols,intervals=spans,interval_endpoints=2*spans,spacing_mm=h,
 remaining_volume_mm3=length*h*h,touching_interval_pairs=touching,retained_core_columns_checked=core_columns,
 screw_invariants_checked=a.check_screw_invariants,validation_seconds=time.perf_counter()-start,
 note='Endpoint count is not a surface-voxel count. Volume is transverse ray quadrature.'),indent=2))
