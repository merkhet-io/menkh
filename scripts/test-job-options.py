#!/usr/bin/env python3
"""CLI voxel override, precedence, validation, and no-resampling contract."""
import copy,json,subprocess,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/job-options';OUT.mkdir(parents=True,exist_ok=True)
EXE=ROOT/('zig-out/bin/menkh.exe' if os.name=='nt' else 'zig-out/bin/menkh')
job={'version':1,'units':'mm','bounds':{'lo':[-1,-1,-1],'hi':[1,1,1]},'voxel_mm':.25,'stock':{'primitives':[{'sphere':{'center':[0,0,0],'radius':.9}}]},'operations':[],'export_mesh':False}
path=OUT/'job.json';path.write_text(json.dumps(job));before=path.read_bytes()
def run(jpath, dest, *options):
 return subprocess.run([str(EXE),'job',str(jpath),'--out',str(OUT/dest),*options],capture_output=True,text=True)
p=run(path,'override','--voxel','0.1');assert p.returncode==0,p.stderr
r=json.loads((OUT/'override/report.json').read_text());assert r['voxel_mm']==.1 and r['input_voxel_mm']==.25 and r['voxel_override_mm']==.1
explicit=copy.deepcopy(job);explicit['voxel_mm']=.1;ep=OUT/'explicit.json';ep.write_text(json.dumps(explicit))
assert run(ep,'explicit').returncode==0
assert (OUT/'explicit/final.menkh').read_bytes()==(OUT/'override/final.menkh').read_bytes()
assert path.read_bytes()==before
for value in ['0','-1','nan','inf','nope']:
 assert run(path,'invalid','--voxel',value).returncode!=0,value
assert run(path,'invalid','--voxel').returncode!=0
resume=copy.deepcopy(job);resume['stock']={'state_file':str(OUT/'override/final.menkh')};rp=OUT/'resume.json';rp.write_text(json.dumps(resume))
assert run(rp,'resume','--voxel','.1').returncode==0
bad=run(rp,'mismatch','--voxel','.2');assert bad.returncode!=0 and 'GridMismatch' in bad.stderr,bad.stderr
print('Job options: override equals explicit JSON, source unchanged, invalid sizes rejected, resume never resampled')
