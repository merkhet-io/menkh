#!/usr/bin/env python3
"""Actual Win32 controls, leased D3D12/WARP views and independent occupancy oracle."""
import argparse, atexit, ctypes, hashlib, json, math, os, shutil, statistics, struct, subprocess, time
from pathlib import Path
assert os.name=='nt','Run on Windows with the native viewer'
p=argparse.ArgumentParser();p.add_argument('--viewer',type=Path,required=True);p.add_argument('--engine',type=Path,required=True);p.add_argument('--library',type=Path,required=True);p.add_argument('--voxel',type=float,default=.025);p.add_argument('--out',type=Path,default=Path('out/windows-live'));a=p.parse_args()
root=a.out.resolve();root.mkdir(parents=True,exist_ok=True);source=root/'inputs café';source.mkdir(exist_ok=True)
viewer=str(a.viewer.resolve());engine=str(a.engine.resolve());library=str(a.library.resolve())
job=dict(version=1,units='mm',bounds=dict(lo=[-3,-2,0],hi=[3,2,3]),voxel_mm=a.voxel,stock=dict(primitives=[dict(box=dict(lo=[-3,-2,0],hi=[3,2,3]))]),tools=[dict(cutter=dict(kind='ball',radius=.45,length=2))],motion_tolerance_mm=.01,export_mesh=False,operations=[])
position=[-2.5,-1.5,1.7]
for row in range(40):
 for col in range(61):
  x=-2.5+5*(col if row%2==0 else 60-col)/60;y=-1.5+3*row/39;end=[x,y,1.5+.3*math.sin(x*1.3)*math.cos(y)]
  job['operations'].append(dict(id=f'row-{row}-step-{col}',tool=0,line=dict(a=dict(position=position),b=dict(position=end))));position=end
baseline=dict(job);file=source/'baseline.json';file.write_text(json.dumps(baseline));expected=root/'expected'
with (root/'baseline.log').open('w') as log:subprocess.run([engine,'job',str(file),'--out',str(expected)],check=True,stdout=log,stderr=log,timeout=180)
# Exercise resolution relative to the original job, even though the viewer
# creates its live-enabled launch copy outside that directory.
seed=dict(job,operations=[]);file.write_text(json.dumps(seed))
with (root/'seed.log').open('w') as log:subprocess.run([engine,'job',str(file),'--out',str(root/'seed')],check=True,stdout=log,stderr=log,timeout=60)
shutil.copyfile(root/'seed/final.menkh',source/'stock.menkh');job['stock']=dict(state_file='stock.menkh')
job['live_inspection']=dict(start_paused=True,history_operations=16,publish_every_operations=1,min_publish_ms=0,max_snapshot_bytes=8*1024*1024)
file=source/'job.json';file.write_text(json.dumps(job));source_bytes=file.read_bytes()
children=[]
@atexit.register
def cleanup():
 for child in children:
  if child.poll() is None:child.kill();child.wait()
def read(path):
 try:return json.loads(path.read_text())
 except (FileNotFoundError,json.JSONDecodeError,PermissionError):return {}
def records(path):
 if not path.exists():return []
 lines=path.read_text().splitlines();result=[]
 for line in lines:
  try:result.append(json.loads(line))
  except json.JSONDecodeError:pass
 return result
def wait(predicate,proc=None,seconds=90):
 deadline=time.monotonic()+seconds
 while time.monotonic()<deadline:
  value=predicate()
  if value:return value
  if proc is not None and proc.poll() is not None:raise AssertionError(f'Viewer exited early: {proc.returncode}')
  time.sleep(.01)
 raise AssertionError('Timed out waiting for live UI/state')
user=ctypes.WinDLL('user32',use_last_error=True)
callback=ctypes.WINFUNCTYPE(ctypes.c_bool,ctypes.c_void_p,ctypes.c_void_p)
user.EnumWindows.argtypes=[callback,ctypes.c_void_p];user.EnumChildWindows.argtypes=[ctypes.c_void_p,callback,ctypes.c_void_p]
user.GetWindowThreadProcessId.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong)]
user.GetClassNameW.argtypes=[ctypes.c_void_p,ctypes.c_wchar_p,ctypes.c_int]
user.GetWindowTextW.argtypes=[ctypes.c_void_p,ctypes.c_wchar_p,ctypes.c_int]
user.GetDlgItem.argtypes=[ctypes.c_void_p,ctypes.c_int];user.GetDlgItem.restype=ctypes.c_void_p
user.SendMessageTimeoutW.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_size_t,ctypes.c_ssize_t,ctypes.c_uint,ctypes.c_uint,ctypes.POINTER(ctypes.c_size_t)];user.SendMessageTimeoutW.restype=ctypes.c_size_t

def message(hwnd,code,w=0,l=0):
 result=ctypes.c_size_t();assert user.SendMessageTimeoutW(hwnd,code,w,l,2,30000,ctypes.byref(result)),('UI did not respond',code,ctypes.get_last_error());return result.value
def classname(hwnd):
 text=ctypes.create_unicode_buffer(256);user.GetClassNameW(hwnd,text,256);return text.value
def text(hwnd):
 value=ctypes.create_unicode_buffer(4096);user.GetWindowTextW(hwnd,value,4096);return value.value
def window(pid,kind):
 found=[]
 @callback
 def visit(hwnd,_):
  owner=ctypes.c_ulong();user.GetWindowThreadProcessId(hwnd,ctypes.byref(owner))
  if owner.value==pid and classname(hwnd)==kind:found.append(hwnd)
  return True
 user.EnumWindows(visit,None);return found[0] if found else None
def status(hwnd):
 found=[]
 @callback
 def visit(child,_):
  if classname(child)=='Static':found.append(text(child))
  return True
 user.EnumChildWindows(hwnd,visit,None);return ' '.join(found)
def click(run,control):message(user.GetDlgItem(run,control),0xF5) # BM_CLICK

def digest(path):return {f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in path.iterdir()}
# Decode occupancy without using the C++ or Zig history implementations.
h=read(expected/'voxel-animation.json');n=h['grid'];nb=h['block_grid'];FULL=0xfffffffe;EMPTY=0xffffffff
valid=[]
for b in range(math.prod(nb)):
 bx=b%nb[0]*8;by=b//nb[0]%nb[1]*8;bz=b//(nb[0]*nb[1])*8
 valid.append(sum(1<<bit for bit in range(512) if bx+bit%8<n[0] and by+bit//8%8<n[1] and bz+bit//64<n[2]))
def state(block_file,pool_file):
 blocks=struct.unpack('<'+'I'*(block_file.stat().st_size//4),block_file.read_bytes());pool=pool_file.read_bytes()
 return [0 if d==EMPTY else valid[b] if d==FULL else int.from_bytes(pool[d*64:(d+1)*64],'little') for b,d in enumerate(blocks)]
oracle=[state(expected/'initial.blocks',expected/'initial.pool')]
for step in h['frames']:
 current=oracle[-1].copy();raw=(expected/step['file']).read_bytes();offset=0
 while offset<len(raw):
  b,before,after=struct.unpack_from('<III',raw,offset);offset+=12
  old=int.from_bytes(raw[offset:offset+64],'little') if before<FULL else valid[b] if before==FULL else 0;offset+=64 if before<FULL else 0
  assert current[b]==old
  current[b]=int.from_bytes(raw[offset:offset+64],'little') if after<FULL else valid[b] if after==FULL else 0;offset+=64 if after<FULL else 0
 oracle.append(current)
summary=[]
for mode in ['process','library']:
 for action in ['complete','cancel','failure']:
  name=f'{mode}-{action}';out=root/name;evidence=root/(name+'-images')
  with (root/(name+'.stdout')).open('w') as stdout,(root/(name+'.stderr')).open('w') as stderr:
   proc=subprocess.Popen([viewer,str(file),'--engine' if mode=='process' else '--library',engine if mode=='process' else library,'--job-output',str(out),'--live','--run-only','--warp','--debug','--live-evidence',str(evidence)],stdout=stdout,stderr=stderr);children.append(proc)
  run=wait(lambda:window(proc.pid,'MenkhCalculation'),proc)
  wait(lambda:read(out/'live/status.json').get('state')=='paused',proc)
  wait(lambda:records(out/'live-viewer.jsonl'),proc)
  view=wait(lambda:window(proc.pid,'MenkhD3D12'),proc)
  click(run,2) # Resume calculation.
  # Pause after cuts have started, without waiting for the throttled renderer.
  wait(lambda:any(x.get('completed_operations',0)>=40 for x in records(out/'progress.jsonl')),proc)
  click(run,2)
  paused=wait(lambda:read(out/'live/status.json') if read(out/'live/status.json').get('state')=='paused' else None,proc)
  completed=paused['completed_operations'];assert 0<completed<len(job['operations'])
  latest=wait(lambda:next((r for r in reversed(records(out/'live-viewer.jsonl')) if r['completed_operations']==completed),None),proc)
  # Actual keyboard scrubbing automatically holds the lease and unchecks Follow.
  message(view,0x100,0x24);wait(lambda:'Frame 0 /' in status(view),proc)
  assert message(user.GetDlgItem(run,3),0xF0)==0
  message(view,0x100,0x23);wait(lambda:f"Frame {completed-latest['first_operation']} /" in status(view),proc)
  pinned=out/f"live/slot-{latest['publication']['slot']}";before=digest(pinned)
  time.sleep(.1);assert read(out/'live/status.json')['completed_operations']==completed
  if action=='complete':
   click(run,2);wait(lambda:any(x.get('completed_operations',0)>=completed+50 for x in records(out/'progress.jsonl')),proc)
   assert digest(pinned)==before,'Producer overwrote a window held by the viewer'
   click(run,3) # Follow latest again.
   code=proc.wait(timeout=240);assert code==0,(name,code,(root/(name+'.stderr')).read_text()[-5000:])
   assert (out/'final.menkh').read_bytes()==(expected/'final.menkh').read_bytes()
  elif action=='cancel':
   click(run,1);assert proc.wait(timeout=60)==2
   assert read(out/'live/status.json')['state']=='cancelled' and not (out/'voxel-animation.json').exists()
   assert digest(pinned)==before
  else:
   (out/f'step-{completed:04}.delta').mkdir();click(run,2);assert proc.wait(timeout=60)==1
   assert read(out/'live/status.json')['state']=='failed' and not (out/'voxel-animation.json').exists()
   assert digest(pinned)==before
  rows=records(out/'live-viewer.jsonl');assert len(rows)>=2
  for row in rows:
   sample=evidence/f"window-{row['sequence']}";meta=read(sample/'window.json')
   assert state(sample/'final.blocks',sample/'final.pool')==oracle[meta['completed_operations']],(name,row['sequence'])
   assert (sample/'latest.ppm').read_bytes()==(sample/'replayed.ppm').read_bytes()
   assert row['render_replay_exact'] and row['verification_enabled']
  errors=(root/(name+'.stderr')).read_text()
  assert 'D3D12: ' not in errors,errors[-6000:]
  summary.append(dict(case=name,paused_operation=completed,windows_checked=len(rows),metrics={key:dict(median=statistics.median(r[key] for r in rows),min=min(r[key] for r in rows),max=max(r[key] for r in rows)) for key in ['load_seek_ms','renderer_setup_ms','upload_ms','attach_render_ms','process_peak_rss_bytes']}))
assert file.read_bytes()==source_bytes
(root/'validation.json').write_text(json.dumps(dict(cases=summary,operations=len(job['operations']),voxel_mm=job['voxel_mm'],independent_occupancy=True,rendered_replay_exact=True,cli_final_state_exact=True,actual_ui_controls=True,note='D3D12 WARP software renderer; times include evidence-mode replay checks, not hardware FPS. DLL RSS includes engine and viewer in one process.'),indent=2))
print(json.dumps(summary,indent=2))
