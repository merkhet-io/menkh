import importlib.util,json,copy,subprocess,pathlib,hashlib
root=pathlib.Path.cwd();spec=importlib.util.spec_from_file_location('workflow',root/'scripts/finishing-workflow.py');w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
out=root/'out/scanline/resume';out.mkdir(parents=True,exist_ok=True);run=root/'out/scanline/paired/after-1';before=root/'out/scanline/paired/before-1';exe=root/'zig-out/bin/menkh';job=json.loads((run/'job.json').read_text());expected=w.inspection.digest(run/'final.menkh');records={}
mid=len(job['operations'])//2;first=copy.deepcopy(job);first['operations']=first['operations'][:mid];records['checkpoint']=w.execute(exe,first,out/'checkpoint')
rest=copy.deepcopy(job);rest['operations']=rest['operations'][mid:];rest['stock']={'state_file':str(out/'checkpoint/final.menkh')};records['resumed']=w.execute(exe,rest,out/'resumed');assert w.inspection.digest(out/'resumed/final.menkh')==expected
subprocess.run([str(exe),'compact-state',str(out/'checkpoint/final.menkh'),str(out/'compact.menkh')],check=True)
rest['stock']={'state_file':str(out/'compact.menkh')};records['compacted_resumed']=w.execute(exe,rest,out/'compacted-resumed');assert w.inspection.digest(out/'compacted-resumed/final.menkh')==expected
deltas=list(before.glob('*.delta'));assert len(deltas)==len(job['operations'])==5199
for f in deltas:assert f.read_bytes()==(run/f.name).read_bytes(),f.name
assert (before/'voxel-animation.json').read_bytes()==(run/'voxel-animation.json').read_bytes()
w.write(out/'reports.json',records)
w.write(out/'summary.json',dict(resume_exact=True,compacted_resume_exact=True,occupancy_sha256=expected,all_5199_deltas_byte_exact=True,history_manifest_byte_exact=True,checkpoint_bytes=(out/'checkpoint/final.menkh').stat().st_size,compacted_bytes=(out/'compact.menkh').stat().st_size))
print('25 µm resume, compacted resume, and all 5199 history deltas match exactly')
