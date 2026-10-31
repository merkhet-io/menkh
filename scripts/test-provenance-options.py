#!/usr/bin/env python3
"""Defaults, CLI precedence and playback retention independent of viewer defaults."""
import argparse, json, os, struct, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/provenance-options'));a=p.parse_args()
root=a.out.resolve();root.mkdir(parents=True,exist_ok=True)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve()
bounds=dict(lo=[0,0,0],hi=[2,2,2])
job=dict(version=1,units='mm',bounds=bounds,voxel_mm=.25,stock=dict(primitives=[dict(box=bounds)]),export_mesh=False,operations=[dict(id='half',subtract=dict(box=dict(lo=[0,0,1],hi=[2,2,2]))),dict(id='clear',subtract=dict(box=bounds))])
expected=None
cases=[('defaults',{},[],'all_frames'),('disabled',dict(export_provenance=False),[],None),('final',dict(provenance_scope='final_surface'),[],'final_surface'),('enable',dict(export_provenance=False,provenance_scope='final_surface'),['--provenance','all_frames'],'all_frames'),('cli-final',{},['--provenance','final_surface'],'final_surface'),('cli-off',{},['--provenance','off'],None),('alias-off',{},['--no-provenance'],None),('last-wins',{},['--no-provenance','--provenance','all_frames'],'all_frames')]
for name,settings,options,scope in cases:
 source=root/(name+'.json');source.write_text(json.dumps(dict(job,**settings)));before=source.read_bytes();dest=root/name
 result=subprocess.run([str(exe),'job',str(source),'--out',str(dest),*options],capture_output=True)
 assert result.returncode==0,result.stderr.decode()
 assert source.read_bytes()==before
 state=(dest/'final.menkh').read_bytes()
 if expected is None:expected=state
 assert state==expected
 report=json.loads((dest/'report.json').read_text());assert report['provenance_scope']==scope
 header=dest/'surface-provenance.json';binary=dest/'surface-provenance.bin'
 if scope is None:assert not header.exists() and not binary.exists();continue
 meta=json.loads(header.read_text());assert meta['scope']==scope
 entries=list(struct.iter_unpack('<QII',binary.read_bytes()))
 if scope=='all_frames':
  # The final stock is empty, but the first cut exposed a plane: its labels must
  # survive for playback. Operation 2 must not replace operation 1's removals.
  assert entries and any(op==1 for _,op,_ in entries)
  assert all(1<=op<=2 and tool==0 for _,op,tool in entries)
 else:assert entries==[]
for index,options in enumerate([['--provenance'],['--provenance','unknown']]):
 dest=root/f'invalid-{index}'
 result=subprocess.run([str(exe),'job',str(root/'defaults.json'),'--out',str(dest),*options],capture_output=True)
 assert result.returncode!=0 and not dest.exists()
print('Provenance defaults, overrides, unchanged jobs/material and historical retention passed')
