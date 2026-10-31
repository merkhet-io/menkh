#!/usr/bin/env python3
"""End-to-end viewer-owned calculation, failure and cancellation checks (no GPU needed)."""
import argparse,copy,ctypes,json,os,shutil,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--viewer',type=Path,required=True);p.add_argument('--library',type=Path);p.add_argument('--engine',type=Path,required=True);p.add_argument('--out',type=Path,default=ROOT/'out/viewer-job-tests');args=p.parse_args()
args.out.mkdir(parents=True,exist_ok=True);out=Path(tempfile.mkdtemp(prefix='run-',dir=args.out.resolve()));source=out/'job inputs café';source.mkdir()
engine_dir=out/'engine with spaces';engine_dir.mkdir();engine=engine_dir/args.engine.name;shutil.copy2(args.engine.resolve(),engine)
viewer=str(args.viewer.resolve())
execution=['--engine',str(engine)]
if args.library:
 library=engine_dir/'library with spaces.dll';shutil.copy2(args.library.resolve(),library);execution=['--library',str(library)]
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf8')
def cli(job,dest):
 r=subprocess.run([str(engine),'job',str(job),'--out',str(dest)],cwd=source,capture_output=True,text=True,timeout=30);assert r.returncode==0,r.stderr
seed={'version':1,'units':'mm','bounds':{'lo':[0,0,0],'hi':[4,4,4]},'voxel_mm':.25,'stock':{'primitives':[{'box':{'lo':[0,0,0],'hi':[4,4,4]}}]},'operations':[],'export_mesh':False}
write(source/'seed.json',seed);cli(source/'seed.json',out/'seed');shutil.copyfile(out/'seed/final.menkh',source/'stock.menkh')
job=copy.deepcopy(seed);job['stock']={'state_file':'stock.menkh'};job['tools']=[{'cutter':{'kind':'flat','radius':.6,'length':2}}]
job['operations']=[{'id':name,'tool':0,'line':{'a':{'position':[.7,2,2]},'b':{'position':[3.3,2,2]}}} for name in ['cut "quoted"\nsecond line','repeat','repeat again']]
file=source/'job with spaces.json';write(file,job);cli(file,out/'expected')
records=[]
def run(name,path,code,*extra):
 dest=out/(name+' result')
 command=[viewer,str(path),*execution,'--job-output',str(dest),'--run-only',*map(str,extra)]
 started=time.perf_counter();r=subprocess.run(command,capture_output=True,text=True,timeout=30)
 (out/(name+'.stdout')).write_text(r.stdout,encoding='utf8');(out/(name+'.stderr')).write_text(r.stderr,encoding='utf8')
 assert r.returncode==code,(name,r.returncode,r.stderr)
 records.append(dict(case=name,exit_code=r.returncode,seconds=time.perf_counter()-started));return dest
result=run('success',file,0)
assert (result/'final.menkh').read_bytes()==(out/'expected/final.menkh').read_bytes()
progress=[json.loads(x) for x in (result/'progress.jsonl').read_text().splitlines()]
assert progress[-1]['phase']=='complete'
assert [x['completed_operations'] for x in progress if x['phase']=='cutting']==[1,2,3]
assert [x['operation'] for x in progress if x['phase']=='cutting']==[x['id'] for x in job['operations']]
assert all(x['version']==1 and x['total_operations']==3 for x in progress)
# An explicit working directory is available for CLI-style resource roots.
elsewhere=out/'elsewhere';elsewhere.mkdir();write(elsewhere/'job.json',job)
explicit=run('working-dir',elsewhere/'job.json',0,'--working-dir',source)
assert (explicit/'final.menkh').read_bytes()==(result/'final.menkh').read_bytes()
# Existing output is never overwritten or accidentally treated as a new result.
before=(result/'final.menkh').read_bytes();run('success',file,1)
assert (result/'final.menkh').read_bytes()==before
bad=copy.deepcopy(job);bad['version']=99;write(source/'invalid.json',bad)
failed=run('invalid',source/'invalid.json',1);assert 'UnsupportedJobVersion' in (failed/'simulation.log').read_text();assert not (failed/'voxel-animation.json').exists()
# Missing engine error cannot launch a process or create a successful output.
r=subprocess.run([viewer,str(file),'--engine',str(out/'absent-engine'),'--run-only'],capture_output=True,text=True,timeout=30);assert r.returncode!=0
long=copy.deepcopy(job);long['operations']=[dict(job['operations'][0],id=f'operation-{i}') for i in range(20000)];write(source/'long.json',long)
cancelled=run('cancelled',source/'long.json',2,'--cancel-after-ms','0');assert not (cancelled/'voxel-animation.json').exists()
launch=json.loads((cancelled/'launch.json').read_text());pid=launch['viewer_pid' if args.library else 'engine_pid']
if args.library:assert launch['mode']=='library' and 'engine_pid' not in launch
def running(pid):
 if os.name=='nt':
  kernel=ctypes.WinDLL('kernel32',use_last_error=True);kernel.OpenProcess.restype=ctypes.c_void_p;kernel.WaitForSingleObject.argtypes=[ctypes.c_void_p,ctypes.c_uint32];kernel.CloseHandle.argtypes=[ctypes.c_void_p]
  handle=kernel.OpenProcess(0x100000,False,pid)
  if not handle:return False
  try:return kernel.WaitForSingleObject(handle,0)==258
  finally:kernel.CloseHandle(handle)
 try:os.kill(pid,0);return True
 except ProcessLookupError:return False
for _ in range(30):
 if not running(pid):break
 time.sleep(.05)
assert not running(pid),'Cancelled engine is still running'
write(out/'validation.json',dict(cases=records,material_matches_cli=True,structured_progress_valid=True,cancelled_child_exited=True,existing_output_preserved=True,relative_paths_valid=True,engine_path_with_spaces=True))
print(f'Viewer job lifecycle passed; evidence: {out}')
