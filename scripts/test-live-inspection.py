#!/usr/bin/env python3
"""Lease/rotation/control tests; compare decoded live occupancy to archive prefixes.
No renderer or GPU needed. POSIX flock / Windows byte-range locks match the publication contract.
"""
import argparse, atexit, hashlib, json, os, shutil, struct, subprocess, time
if os.name == "nt":
 import msvcrt
 def acquire(file):msvcrt.locking(file.fileno(),msvcrt.LK_NBRLCK,1)
else:
 import fcntl
 def acquire(file):fcntl.flock(file,fcntl.LOCK_SH|fcntl.LOCK_NB)
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/live-test'));args=p.parse_args()
root=args.out.resolve();root.mkdir(parents=True,exist_ok=True)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve()
bounds=dict(lo=[-.35,-.2,-.15],hi=[7.78,6.33,4.78])
job=dict(version=1,units='mm',bounds=bounds,voxel_mm=.1,stock=dict(primitives=[dict(box=bounds)]),export_mesh=False,operations=[])
for i in range(1200):
 x=(i%80)*.1-.35;y=(i//80%64)*.1-.2
 job['operations'].append(dict(id=f'cut-{i}',subtract=dict(sphere=dict(center=[x,y,3.25],radius=.37))))
children=[]
def cleanup():
 for child in children:
  if child.poll() is None:child.kill();child.wait()
atexit.register(cleanup)
opts=dict(start_paused=True,history_operations=16,publish_every_operations=1,min_publish_ms=0,max_snapshot_bytes=4*1024*1024)
def wait(pred, seconds=30):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=pred()
  if value:return value
  time.sleep(.002)
 raise AssertionError('timeout')
def read(path):
 try:return json.loads(path.read_text())
 except (FileNotFoundError,json.JSONDecodeError):return {}
def launch(name,config):
 out=root/name
 if out.exists():shutil.rmtree(out)
 file=root/(name+'.json');file.write_text(json.dumps(config));log=(root/(name+'.log')).open('w')
 proc=subprocess.Popen([str(exe),'job',str(file),'--out',str(out)],stdout=log,stderr=log);children.append(proc);log.close()
 return proc,out
def lease(out):
 info=read(out/'live/latest.json')
 if not info:return
 lock=(out/f"live/slot-{info['slot']}.lock").open('rb')
 try:acquire(lock)
 except OSError:lock.close();return
 path=out/f"live/slot-{info['slot']}"
 meta=read(path/'voxel-animation.json')
 if meta.get('live_sequence')!=info['sequence']:lock.close();return
 return lock,path,meta
def digest(path):return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in path.iterdir()}
def decode(path):
 h=read(path/'voxel-animation.json');nb=h['block_grid'];n=h['grid']
 descriptors=list(struct.unpack('<'+'I'*((path/'initial.blocks').stat().st_size//4),(path/'initial.blocks').read_bytes()));pool=(path/'initial.pool').read_bytes()
 def value(b,d,data=None):
  if d==0xffffffff:return 0
  if d==0xfffffffe:
   bx=b%nb[0]*8;by=b//nb[0]%nb[1]*8;bz=b//(nb[0]*nb[1])*8
   return sum(1<<bit for bit in range(512) if bx+bit%8<n[0] and by+bit//8%8<n[1] and bz+bit//64<n[2])
  return int.from_bytes(data if data is not None else pool[d*64:(d+1)*64],'little')
 state=[value(b,d) for b,d in enumerate(descriptors)];result=[state.copy()]
 for f in h['frames']:
  raw=(path/f['file']).read_bytes();assert len(raw)==f['delta_bytes'];offset=0;records=0
  while offset<len(raw):
   b,before,after=struct.unpack_from('<III',raw,offset);offset+=12
   old=raw[offset:offset+64] if before<0xfffffffe else None;offset+=64 if old is not None else 0
   new=raw[offset:offset+64] if after<0xfffffffe else None;offset+=64 if new is not None else 0
   assert descriptors[b]==before and state[b]==value(b,before,old)
   descriptors[b]=after;state[b]=value(b,after,new);records+=1
  assert records==f['changed_blocks'] and sum(v.bit_count() for v in state)==f['occupied']
  result.append(state.copy())
 return result
base,out=launch('baseline',job);assert base.wait(timeout=60)==0
oracle=decode(out)
proc,out=launch('live',dict(job,live_inspection=opts))
wait(lambda:read(out/'live/status.json').get('state')=='paused')
held=[wait(lambda:lease(out))];initial_digest=digest(held[0][1]);samples=[]
(out/'live/pause').unlink()
# Pin every slot: producer must skip without blocking or mutating leased windows.
while len(held)<3:
 item=wait(lambda:lease(out))
 if item[2]['live_sequence'] not in [x[2]['live_sequence'] for x in held]:held.append(item)
 else:item[0].close()
assert proc.wait(timeout=60)==0
for lock,path,meta in held:
 states=decode(path);start=meta['first_operation'];assert states==oracle[start:start+len(states)]
 samples.append(dict(first=start,last=meta['completed_operations'],sequence=meta['live_sequence']))
assert digest(held[0][1])==initial_digest
for lock,_,_ in held:lock.close()
assert (out/'final.menkh').read_bytes()==(root/'baseline/final.menkh').read_bytes()
report=read(out/'report.json');assert report['live_publication']['skipped']>0
assert len(list((out/'live').glob('slot-*')))==6
# Follow a rotating channel; validate rebased windows, then pause and seek all
# retained frames against independent archive-prefix decoding.
proc,stream=launch('stream',dict(job,live_inspection=dict(opts,start_paused=False)))
seen=set();rebased=0
while proc.poll() is None:
 item=lease(stream)
 if item:
  lock,path,meta=item
  if meta['live_sequence'] not in seen:
   states=decode(path);start=meta['first_operation']
   assert states==oracle[start:start+len(states)]
   seen.add(meta['live_sequence']);rebased+=start>0
  lock.close()
 time.sleep(.001)
assert proc.returncode==0, (proc.returncode, read(stream/'live/status.json'), (root/'stream.log').read_text()[-8000:])
assert rebased>0, dict(seen=sorted(seen), latest=read(stream/'live/latest.json'))
item=wait(lambda:lease(stream));states=decode(item[1]);meta=item[2]
assert meta['completed_operations']==len(job['operations'])
assert states==oracle[meta['first_operation']:];item[0].close()
assert (stream/'final.menkh').read_bytes()==(root/'baseline/final.menkh').read_bytes()
# A paused producer remains stationary, cancellation unblocks it and leaves a usable window.
proc,cancel=launch('cancel',dict(job,live_inspection=opts))
wait(lambda:read(cancel/'live/status.json').get('state')=='paused')
item=wait(lambda:lease(cancel));before=digest(item[1]);time.sleep(.05)
assert read(cancel/'live/latest.json')['completed_operations']==0
(cancel/'live/cancel').touch();assert proc.wait(timeout=30)!=0
assert read(cancel/'live/status.json')['state']=='cancelled' and digest(item[1])==before
assert not (cancel/'voxel-animation.json').exists();item[0].close()
# Even a zero-cut job honors start_paused and can resume to its exact initial state.
proc,empty=launch('zero',dict(job,operations=[],live_inspection=opts))
wait(lambda:read(empty/'live/status.json').get('state')=='paused')
(empty/'live/pause').unlink();assert proc.wait(timeout=30)==0
assert read(empty/'live/status.json')['state']=='complete'
assert read(empty/'voxel-animation.json')['frames']==[]
# Inject an archival write failure after the initial publication. Readers keep that state.
proc,failed=launch('failed',dict(job,live_inspection=opts))
wait(lambda:read(failed/'live/status.json').get('state')=='paused')
item=wait(lambda:lease(failed));before=digest(item[1]);(failed/'step-0000.delta').mkdir();(failed/'live/pause').unlink()
assert proc.wait(timeout=30)!=0 and read(failed/'live/status.json')['state']=='failed'
assert digest(item[1])==before and not (failed/'voxel-animation.json').exists();item[0].close()
# Explicit budgets and validation fail; no completed manifest is published.
for name,changes in [('budget',dict(max_snapshot_bytes=4096,start_paused=False)),('invalid',dict(history_operations=0))]:
 proc,bad=launch(name,dict(job,live_inspection=dict(opts,**changes)))
 assert proc.wait(timeout=30)!=0 and not (bad/'voxel-animation.json').exists()
summary=dict(operations=len(job['operations']),validated_windows=samples,rotating_windows_checked=len(seen),rebased_windows_checked=rebased,final_state_identical=True,lease_backpressure=report['live_publication'],peak_rss_bytes=report['process_peak_rss_bytes'],pause_cancel_failure=True)
(root/'validation.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
