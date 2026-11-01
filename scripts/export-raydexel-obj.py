#!/usr/bin/env python3
"""Display/export the continuous Z-column solid; no normal or geometry smoothing.

Each sampled ray represents its square transverse cell. This is a derived column
solid, not a reconstructed subvoxel surface. Shared interior faces are omitted.
"""
import argparse, json, math, struct, time
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('manifest',type=Path)
p.add_argument('output',type=Path)
p.add_argument('--validate-edges',action='store_true',help='check oriented edge coverage including collinear T-junction subdivisions')
a=p.parse_args();start=time.perf_counter()
r=json.loads(a.manifest.read_text())
assert r['format']=='menkh-experimental-z-rays-v1' and r['units']=='mm'
assert Path(r['file']).name==r['file'], 'Expected a sibling data file'
cols,spans=r['columns'],r['intervals']
assert type(cols) is int and type(spans) is int and cols>=0 and spans>=0
assert cols*24+spans*16<=256*1024*1024, 'Exporter input limit is 256 MiB'
data=(a.manifest.parent/r['file']).read_bytes()
assert len(data)==cols*24+spans*16, 'Truncated or trailing interval data'
h=r['spacing_mm'];origin=r['origin'];dims=r['grid_xy']
assert math.isfinite(h) and h>0 and len(origin)==3 and all(math.isfinite(v) for v in origin)
assert len(dims)==2 and all(type(n) is int and 0<n<=65536 for n in dims)
columns={};expected_offset=0;previous=-1
for i in range(cols):
 x,y,offset,count=struct.unpack_from('<IIQQ',data,i*24)
 assert x<dims[0] and y<dims[1] and y*dims[0]+x>previous
 assert offset==expected_offset and offset+count<=spans
 intervals=[struct.unpack_from('<dd',data,cols*24+(offset+j)*16) for j in range(count)]
 last=-math.inf
 for lo,hi in intervals:
  assert math.isfinite(lo) and math.isfinite(hi) and lo<hi and lo>=last
  last=hi
 columns[x,y]=intervals;expected_offset+=count;previous=y*dims[0]+x
assert expected_offset==spans
expected_volume=math.fsum((hi-lo)*h*h for intervals in columns.values() for lo,hi in intervals)

def difference(intervals,neighbors):
 for lo,hi in intervals:
  at=lo
  for nlo,nhi in neighbors:
   if nhi<=at: continue
   if nlo>=hi: break
   if nlo>at: yield at,min(nlo,hi)
   at=max(at,nhi)
   if at>=hi: break
  if at<hi: yield at,hi

def cross(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def dot(a,b):return sum(x*y for x,y in zip(a,b))
edges={};faces=0;volume_terms=[]
a.output.parent.mkdir(parents=True,exist_ok=True)
with a.output.open('x',buffering=1024*1024) as out:
 out.write('# Continuous Z-column solid; transverse cells are piecewise constant. No smoothing.\n')
 def face(points):
  global faces
  world=[(origin[0]+x*h,origin[1]+y*h,z) for x,y,z in points]
  for v in world: out.write('v '+' '.join(format(n,'.17g') for n in v)+'\n')
  first=4*faces+1;out.write(f'f {first} {first+1} {first+2} {first+3}\n');faces+=1
  volume_terms.append((dot(world[0],cross(world[1],world[2]))+dot(world[0],cross(world[2],world[3])))/6)
  if a.validate_edges:
   for u,v in zip(points,points[1:]+points[:1]):
    axes=[k for k in range(3) if u[k]!=v[k]];assert len(axes)==1
    axis=axes[0];key=(axis,*(u[k] for k in range(3) if k!=axis));events=edges.setdefault(key,{})
    lo,hi=sorted([u[axis],v[axis]]);sign=1 if v[axis]>u[axis] else -1
    events[lo]=events.get(lo,0)+sign;events[hi]=events.get(hi,0)-sign
 for (x,y),intervals in columns.items():
  for lo,hi in intervals:
   face([(x,y,lo),(x,y+1,lo),(x+1,y+1,lo),(x+1,y,lo)])
   face([(x,y,hi),(x+1,y,hi),(x+1,y+1,hi),(x,y+1,hi)])
  for lo,hi in difference(intervals,columns.get((x-1,y),[])):
   face([(x,y+1,lo),(x,y,lo),(x,y,hi),(x,y+1,hi)])
  for lo,hi in difference(intervals,columns.get((x+1,y),[])):
   face([(x+1,y,lo),(x+1,y+1,lo),(x+1,y+1,hi),(x+1,y,hi)])
  for lo,hi in difference(intervals,columns.get((x,y-1),[])):
   face([(x,y,lo),(x+1,y,lo),(x+1,y,hi),(x,y,hi)])
  for lo,hi in difference(intervals,columns.get((x,y+1),[])):
   face([(x+1,y+1,lo),(x,y+1,lo),(x,y+1,hi),(x+1,y+1,hi)])
volume=math.fsum(volume_terms)
assert abs(volume-expected_volume)<=1e-8*max(1,expected_volume), 'Oriented mesh volume differs from interval volume'
if a.validate_edges:
 assert all(all(value==0 for value in events.values()) for events in edges.values()), 'Unbalanced oriented edges'
report=dict(faces=faces,mesh_volume_mm3=volume,interval_volume_mm3=expected_volume,
            oriented_edge_coverage_checked=a.validate_edges,export_seconds=time.perf_counter()-start,
            note='Column-solid surface, no smoothing. Geometric edge coverage allows collinear T-junctions; not a conforming indexed mesh guarantee.')
a.output.with_suffix('.report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
