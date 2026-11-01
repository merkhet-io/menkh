#!/usr/bin/env python3
"""Independent sampled endpoint distances to the frozen screw's continuous tool union.

Uses meridian segment distances and Lipschitz time subdivision, not the Zig ray
solver. Only this frozen crown/constant-A XYZAC workload is accepted.
"""
import argparse, hashlib, heapq, json, math, random, struct, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('directory',type=Path)
p.add_argument('--samples',type=int,default=128)
p.add_argument('--epsilon',type=float,default=.0005,help='time-minimization interval width in mm')
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
if not 1<=a.samples<=4096 or not 0<a.epsilon<=.01:p.error('invalid sample count or epsilon')
job=json.loads((a.directory/'job.json').read_text())
manifest=json.loads((a.directory/'intervals.json').read_text())
report=json.loads((a.directory/'report.json').read_text())
assert job['units']=='mm' and manifest['units']=='mm' and manifest['format']=='menkh-experimental-z-rays-v1'
assert len(job['tools'])==1 and len(job['operations'])==1024
assert 0 < (a.directory/'intervals.bin').stat().st_size <= 256*1024*1024
tool=job['tools'][0]['cutter']
assert tool['kind']=='profile' and tool['radius']==8 and tool['length']==2
profile=[(v['radius'],v['z']) for v in tool['profile']]
assert profile==[(7,0),(8,.8),(8,1.2),(7,2)]
def segment_distance(r,z,first,second):
 dr=second[0]-first[0];dz=second[1]-first[1]
 t=max(0.,min(1.,((r-first[0])*dr+(z-first[1])*dz)/(dr*dr+dz*dz)))
 return math.hypot(r-first[0]-t*dr,z-first[1]-t*dz)
def meridian(r,z):
 distances=[math.hypot(max(0.,r-7),z),math.hypot(max(0.,r-7),z-2)]
 distances.extend(segment_distance(r,z,x,y) for x,y in zip(profile,profile[1:]))
 inside=0<=z<=2 and r<=min(7+1.25*z,8,9.5-1.25*z)
 value=min(distances)
 return -value if inside else value
# Independently known distances, including full finite caps and conical rim.
assert abs(meridian(0,1)+1)<1e-12 and abs(meridian(8,1))<1e-12
assert abs(meridian(9,1)-1)<1e-12 and abs(meridian(0,3)-1)<1e-12
assert abs(meridian(7.5,.4))<1e-12
ops=[]
for op in job['operations']:
 assert op['tool']==0 and op['rotary'] is not None
 line=op['rotary'];lo=line['a'];hi=line['b']
 assert lo['a_deg']==hi['a_deg']
 angle=math.radians(lo['a_deg']);c=math.radians(lo['c_deg']);dc=math.radians(hi['c_deg']-lo['c_deg'])
 origin=lo['position'];movement=[y-x for x,y in zip(origin,hi['position'])]
 speed=math.sqrt(sum(x*x for x in movement))+math.sqrt(65)*abs(math.sin(angle)*dc)
 ops.append((origin,movement,math.sin(angle),math.cos(angle),c,dc,speed))
def distance(point,op,t):
 origin,movement,sa,ca,c,dc,_=op
 angle=c+dc*t;axis=(math.sin(angle)*sa,-math.cos(angle)*sa,ca)
 q=[point[i]-origin[i]-movement[i]*t for i in range(3)]
 axial=sum(q[i]*axis[i] for i in range(3))
 radial=math.sqrt(sum((q[i]-axial*axis[i])**2 for i in range(3)))
 return meridian(radial,axial+1)
def minimum(point):
 heap=[];upper=math.inf;calls=0
 for i,op in enumerate(ops):
  value=distance(point,op,.5);calls+=1;upper=min(upper,value)
  heap.append((value-op[-1]/2-1e-10,i,0.,1.))
 heapq.heapify(heap)
 while heap[0][0]<upper-a.epsilon:
  _,i,lo,hi=heapq.heappop(heap);mid=(lo+hi)/2
  for first,last in [(lo,mid),(mid,hi)]:
   value=distance(point,ops[i],(first+last)/2);calls+=1;upper=min(upper,value)
   heapq.heappush(heap,(value-ops[i][-1]*(last-first)/2-1e-10,i,first,last))
  if calls>2_000_000:raise RuntimeError('Time oracle budget exceeded; no accuracy claim')
 return heap[0][0],upper,calls
# Uniform deterministic reservoir over internal cut endpoints, not stock caps.
data=(a.directory/'intervals.bin').read_bytes();cols=manifest['columns'];spans=manifest['intervals']
assert len(data)==cols*24+spans*16
rng=random.Random(73582);samples=[];seen=0
for i in range(cols):
 x,y,offset,count=struct.unpack_from('<IIQQ',data,i*24)
 for j in range(2*count):
  z=struct.unpack_from('<d',data,cols*24+offset*16+j*8)[0]
  if not 0<z<40:continue
  point=[manifest['origin'][0]+(x+.5)*manifest['spacing_mm'],manifest['origin'][1]+(y+.5)*manifest['spacing_mm'],z]
  seen+=1
  if len(samples)<a.samples:samples.append(point)
  else:
   index=rng.randrange(seen)
   if index<a.samples:samples[index]=point
start=time.perf_counter();rows=[]
for point in samples:
 lo,hi,calls=minimum(point)
 assert lo<=hi+1e-9
 # Signed distance <0 would place an exported cut endpoint inside a true tool.
 assert hi>=-1e-8, ('Possible missed removal',point,lo,hi)
 assert lo<=report['motion_over_removal_bound_mm']+1e-8, ('Bound violation',point,lo,hi)
 rows.append(dict(point=point,distance_lower_mm=lo,distance_upper_mm=hi,point_pose_evaluations=calls))
result=dict(method=report['method'],spacing_mm=manifest['spacing_mm'],eligible_endpoints=seen,samples=len(rows),epsilon_mm=a.epsilon,
 max_sampled_upper_mm=max(r['distance_upper_mm'] for r in rows),min_sampled_lower_mm=min(r['distance_lower_mm'] for r in rows),
 declared_motion_bound_mm=report['motion_over_removal_bound_mm'],elapsed_seconds=time.perf_counter()-start,
 job_sha256=hashlib.sha256((a.directory/'job.json').read_bytes()).hexdigest(),interval_sha256=hashlib.sha256(data).hexdigest(),
 note='Independent sampled output-endpoint to continuous-tool-union distances. Lipschitz time brackets in real arithmetic with practical f64 guard; no certified Hausdorff claim, reverse surface coverage or XY reconstruction bound.',rows=rows)
a.out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2))
