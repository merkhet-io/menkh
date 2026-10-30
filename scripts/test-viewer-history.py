#!/usr/bin/env python3
"""Negative tests for the standalone viewer's existing-history reader."""
import argparse, json, pathlib, shutil, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('--exe',required=True);p.add_argument('--history',required=True);p.add_argument('--viewer',action='store_true');a=p.parse_args()
exe=str(pathlib.Path(a.exe).resolve());original=pathlib.Path(a.history).resolve()
def run(file,valid):
    r=subprocess.run([exe,str(file)]+(['--verify-history'] if a.viewer else []),capture_output=True)
    if (r.returncode==0)!=valid: raise RuntimeError(f'Unexpected reader result: {r.returncode}: {r.stderr.decode(errors="replace")}')
run(original,True)
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);shutil.copyfile(original.parent/'initial.blocks',root/'initial.blocks');shutil.copyfile(original.parent/'initial.pool',root/'initial.pool')
    job=json.loads(original.read_text());file=root/'history.json'
    cases=[]
    for key,value in [('format','unsupported'),('grid',[0,960,640]),('pool_slots',0),('voxel_mm',0)]:
        changed=json.loads(json.dumps(job));changed[key]=value;cases.append(changed)
    changed=json.loads(json.dumps(job));changed['frames'][0]['file']='../escape.delta';cases.append(changed)
    changed=json.loads(json.dumps(job));changed['frames'][0]['changed_blocks']=1234;cases.append(changed)
    for changed in cases:file.write_text(json.dumps(changed));run(file,False)
    # A valid manifest with a truncated delta must fail, not silently skip it.
    for step in job['frames']:shutil.copyfile(original.parent/step['file'],root/step['file'])
    file.write_text(json.dumps(job));step=next(s for s in job['frames'] if s['delta_bytes']);f=root/step['file'];f.write_bytes(f.read_bytes()[:-1]);run(file,False)
print('Valid history replay and 7 malformed-input cases passed')
