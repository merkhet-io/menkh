#!/usr/bin/env python3
"""Independent cell chronology and every-frame face oracle (ragged blocks/origin)."""
import argparse, copy, json, os, random, struct, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/playback-provenance'));args=p.parse_args();root=args.out.resolve();root.mkdir(parents=True,exist_ok=True)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve()
bounds=dict(lo=[-1.7,-1.9,-.7],hi=[1.7,1.9,1.9])
job=dict(version=1,units='mm',bounds=bounds,voxel_mm=.2,stock=dict(primitives=[dict(cylinder=dict(base=[0,0,-.7],radius=1.6,length=2.6))]),tools=[dict(cutter=dict(kind='flat',radius=.65,length=3)),dict(cutter=dict(kind='flat',radius=.9,length=3))],operations=[],export_mesh=False,export_provenance=True)
for i,(tool,z) in enumerate([(0,.8),(0,.8),(1,.2)]):
 job['operations'].append(dict(id=f'pocket-{i}',tool=tool,line=dict(a=dict(position=[-.6,0,z]),b=dict(position=[.6,0,z]))))
for axis in range(3):
 box=copy.deepcopy(bounds);box['lo'][axis]=-.1;box['hi'][axis]=.25
 job['operations'].append(dict(id=f'section-{axis}',subtract=dict(box=box)))
rng=random.Random(12)
for i in range(12):
 lo=[rng.uniform(a,b-.2) for a,b in zip(bounds['lo'],bounds['hi'])];hi=[min(b,x+rng.uniform(.1,1)) for x,b in zip(lo,bounds['hi'])]
 job['operations'].append(dict(id=f'random-{i}',subtract=dict(box=dict(lo=lo,hi=hi))))
job['operations'].append(dict(id='clear',subtract=dict(box=bounds)))
def run(scope):
 dest=root/scope;dest.mkdir(exist_ok=True);j=dict(job,provenance_scope=scope);file=dest/'job.json';file.write_text(json.dumps(j))
 with (dest/'run.log').open('w') as log:subprocess.run([str(exe),'job',str(file),'--out',str(dest)],check=True,stdout=log,stderr=log)
 return dest
all_frames=run('all_frames');final=run('final_surface');assert (all_frames/'final.menkh').read_bytes()==(final/'final.menkh').read_bytes()
h=json.loads((all_frames/'voxel-animation.json').read_text());n=h['grid'];nb=h['block_grid'];FULL=0xfffffffe;EMPTY=0xffffffff
blocks=list(struct.unpack('<'+'I'*((all_frames/'initial.blocks').stat().st_size//4),(all_frames/'initial.blocks').read_bytes()));pool=(all_frames/'initial.pool').read_bytes()
def coord(b,bit):return (b%nb[0]*8+bit%8,b//nb[0]%nb[1]*8+bit//8%8,b//(nb[0]*nb[1])*8+bit//64)
def inside(p):return all(0<=x<size for x,size in zip(p,n))
def key(p):return (p[2]*n[1]+p[1])*n[0]+p[0]
def fullbits(b):return sum(1<<bit for bit in range(512) if inside(coord(b,bit)))
def bits(b,d):return 0 if d==EMPTY else fullbits(b) if d==FULL else int.from_bytes(pool[d*64:(d+1)*64],'little')
state=[bits(b,d) for b,d in enumerate(blocks)];when={};union={};oracles=[]
actual={cell:(op,tool) for cell,op,tool in struct.iter_unpack('<QII',(all_frames/'surface-provenance.bin').read_bytes())}
def occupied(p):
 if not inside(p):return False
 b=(p[2]//8*nb[1]+p[1]//8)*nb[0]+p[0]//8;bit=p[2]%8*64+p[1]%8*8+p[0]%8
 return bool(state[b]&(1<<bit))
def check_frame(frame):
 expected={};neighbors={}
 for z in range(n[2]):
  for y in range(n[1]):
   for x in range(n[0]):
    cell=(x,y,z)
    if not occupied(cell):continue
    for axis in range(3):
     for side in [-1,1]:
      q=list(cell);q[axis]+=side
      if not inside(q) or occupied(q):continue
      k=key(q);op=when.get(k,0);tool=job['operations'][op-1].get('tool') if op else None
      label=(op,0 if tool is None else tool+1)
      assert actual.get(k,(0,0))==label,(frame,q,actual.get(k),label)
      neighbors[k]=label
      if op:expected[k]=label
 # Probe all future-removal keys too: queries must not expose future IDs.
 for k,(op,tool) in actual.items():
  if op>frame:neighbors[k]=(0,0)
 union.update(expected);oracles.append(dict(frame=frame,neighbors=[[k,*v] for k,v in sorted(neighbors.items())]))
 return expected
check_frame(0)
for op,f in enumerate(h['frames'],1):
 data=(all_frames/f['file']).read_bytes();cursor=0
 while cursor<len(data):
  b,old,new=struct.unpack_from('<III',data,cursor);cursor+=12;m=[]
  for d in [old,new]:
   if d<FULL:m.append(int.from_bytes(data[cursor:cursor+64],'little'));cursor+=64
   else:m.append(bits(b,d))
  assert m[0]==state[b] and not m[1]&~m[0]
  removed=m[0]&~m[1]
  while removed:
   bit=(removed&-removed).bit_length()-1;removed&=removed-1;cell=coord(b,bit);assert inside(cell)
   k=key(cell);assert k not in when;when[k]=op
  state[b]=m[1]
 last=check_frame(op)
assert union==actual and len(actual)>0
final_actual={cell:(op,tool) for cell,op,tool in struct.iter_unpack('<QII',(final/'surface-provenance.bin').read_bytes())}
assert final_actual==last=={},'Removed transient surfaces must survive only in all_frames index'
assert oracles[1]['neighbors']==oracles[2]['neighbors'],'Idempotent cut must not relabel faces'
(all_frames/'oracle.json').write_text(json.dumps(oracles))
(root/'validation.json').write_text(json.dumps(dict(frames=len(oracles),entries=len(actual),all_frames_exact=True,final_mode_preserved=True,final_state_byte_exact=True,transient_surfaces_retained=True),indent=2)+'\n')
print(f'Playback provenance: {len(oracles)} frames and {len(actual)} historical surface neighbors independently verified')
