#!/usr/bin/env python3
"""Independent per-cell history replay oracle for final face exposure attribution."""
import argparse,json,struct,subprocess,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'out/provenance-test');args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
job=json.loads((ROOT/'examples/general.json').read_text());job['export_mesh']=False;job['export_provenance']=True;job['provenance_scope']='final_surface'
(out/'job.json').write_text(json.dumps(job));exe=ROOT/('zig-out/bin/menkh.exe' if os.name=='nt' else 'zig-out/bin/menkh')
with (out/'run.log').open('w') as log:subprocess.run([str(exe),'job',str(out/'job.json'),'--out',str(out)],check=True,stdout=log,stderr=log)
h=json.loads((out/'voxel-animation.json').read_text());n=h['grid'];nb=h['block_grid'];full=0xfffffffe;empty=0xffffffff
blocks=list(struct.unpack('<'+'I'*((out/'initial.blocks').stat().st_size//4),(out/'initial.blocks').read_bytes()));pool=(out/'initial.pool').read_bytes()
def bits(d):return 0 if d==empty else (1<<512)-1 if d==full else int.from_bytes(pool[d*64:(d+1)*64],'little')
state=[bits(d) for d in blocks];when={}
def coord(b,bit):return (b%nb[0]*8+bit%8,b//nb[0]%nb[1]*8+bit//8%8,b//(nb[0]*nb[1])*8+bit//64)
def flat(p):return (p[2]*n[1]+p[1])*n[0]+p[0]
for op,f in enumerate(h['frames'],1):
 data=(out/f['file']).read_bytes();cursor=0
 while cursor<len(data):
  b,old,new=struct.unpack_from('<III',data,cursor);cursor+=12;m=[]
  for d in [old,new]:
   if d<full:m.append(int.from_bytes(data[cursor:cursor+64],'little'));cursor+=64
   else:m.append(bits(d))
  assert m[0]==state[b] and not m[1]&~m[0]
  removed=m[0]&~m[1]
  while removed:
   bit=(removed&-removed).bit_length()-1;removed&=removed-1;key=flat(coord(b,bit));assert key not in when;when[key]=op
  state[b]=m[1]
def occupied(p):
 if any(x<0 or x>=size for x,size in zip(p,n)):return False
 b=(p[2]//8*nb[1]+p[1]//8)*nb[0]+p[0]//8;bit=p[2]%8*64+p[1]%8*8+p[0]%8
 return bool(state[b]&(1<<bit))
expected={}
for z in range(n[2]):
 for y in range(n[1]):
  for x in range(n[0]):
   cell=(x,y,z)
   if not occupied(cell):continue
   for axis in range(3):
    for side in [-1,1]:
     neighbor=list(cell);neighbor[axis]+=side
     if any(q<0 or q>=size for q,size in zip(neighbor,n)) or occupied(neighbor):continue
     key=flat(neighbor)
     if key in when:
      op=when[key];tool=job['operations'][op-1].get('tool');expected[key]=(op,0 if tool is None else tool+1)
actual={key:(op,tool) for key,op,tool in struct.iter_unpack('<QII',(out/'surface-provenance.bin').read_bytes())}
assert expected==actual
header=json.loads((out/'surface-provenance.json').read_text());assert header['entries']==len(actual)
print(f'Independent full-grid, per-cell replay oracle: {len(actual)} final exposure neighbors agree exactly')
