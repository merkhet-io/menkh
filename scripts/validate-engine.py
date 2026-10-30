#!/usr/bin/env python3
"""CLI integration: checkpoint resume, compaction, invalid inputs, STL fixtures, mesh closure."""
import copy, json, pathlib, subprocess
import importlib.util
spec=importlib.util.spec_from_file_location('suite',pathlib.Path(__file__).with_name('benchmark-engine.py'))
suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
ROOT=pathlib.Path(__file__).resolve().parents[1];out=ROOT/'out/integration';out.mkdir(parents=True,exist_ok=True)
base=json.loads((ROOT/'examples/general.json').read_text())
full=suite.run(base,out/'full.json',out/'full')
contact=next(op for op in full['operations'] if op['id']=='intentional-holder-contact')
assert contact['shank_stock']['occupied_centers']>0 and contact['holder_fixture']['occupied_centers']>0
first=copy.deepcopy(base);first['operations']=first['operations'][:3]
suite.run(first,out/'first.json',out/'first')
second=copy.deepcopy(base);second['stock']={'state_file':str(out/'first/final.menkh')};second['operations']=second['operations'][3:]
suite.run(second,out/'resume.json',out/'resume')
assert suite.state(out/'full/final.menkh')==suite.state(out/'resume/final.menkh')
subprocess.run([str(suite.EXE),'compact-state',str(out/'first/final.menkh'),str(out/'compact.menkh')],check=True)
second['stock']={'state_file':str(out/'compact.menkh')}
suite.run(second,out/'compact-resume.json',out/'compact-resume')
assert suite.state(out/'full/final.menkh')==suite.state(out/'compact-resume/final.menkh')
def reject(j, expected):
    suite.write(out/'invalid.json',j)
    p=subprocess.run([str(suite.EXE),'job',str(out/'invalid.json'),'--out',str(out/'invalid')],capture_output=True,text=True)
    assert p.returncode!=0 and expected in p.stderr,(expected,p.stderr)
wrong=copy.deepcopy(base);wrong['version']=2;reject(wrong,'UnsupportedJobVersion')
wrong=copy.deepcopy(base);wrong['tools'][0]['cutter']['radius']=-1;reject(wrong,'InvalidDimension')
wrong=copy.deepcopy(base);wrong['operations'][0]['line']['b']['axis']=[1,0,0];reject(wrong,'OrientationChangeUnsupported')
wrong=copy.deepcopy(base);wrong['units']='inch';reject(wrong,'UnitsMustBeMillimeters')
wrong=copy.deepcopy(base);wrong['unrecognized']=True;reject(wrong,'UnknownField')
corrupt=bytearray((out/'first/final.menkh').read_bytes());corrupt[-1]^=1;(out/'corrupt.menkh').write_bytes(corrupt)
wrong=copy.deepcopy(base);wrong['stock']={'state_file':str(out/'corrupt.menkh')};reject(wrong,'ChecksumMismatch')
suite.closed_mesh(out/'full/surface.obj',base['voxel_mm'])
cells={(x,y,z) for x in range(3) for y in range(3) for z in range(3) if (x,y,z)!=(1,1,1)}
suite.stl_fixture(out/'target-cavity.stl',cells)
mesh_job=suite.job();mesh_job['target']={'stl':{'path':str(out/'target-cavity.stl'),'unit_scale_mm':1}}
mesh_report=suite.run(mesh_job,out/'mesh-target.json',out/'mesh-target')
assert mesh_report['target_comparison']['common']==26*64
assert mesh_report['target_comparison']['missing']==0
report=dict(resume_voxel_exact=True,stl_target_cavity_comparison_validated=True,compacted_resume_voxel_exact=True,invalid_inputs_rejected=6,noncutting_stock_and_fixture_contact_reported=True,oriented_mesh_boundary_closed=True,final_occupied=full['remaining_occupied'])
suite.write(out/'validation.json',report);print(json.dumps(report,indent=2))
