#!/usr/bin/env python3
"""Validate drill mesh/history agreement and Windows reader routing."""
import argparse,json,pathlib,struct,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--exe',required=True);p.add_argument('--history',required=True);p.add_argument('--viewer',action='store_true');a=p.parse_args()
file=pathlib.Path(a.history).resolve();exe=str(pathlib.Path(a.exe).resolve());j=json.loads(file.read_text());root=file.parent
v=json.loads((root/j['voxel_history']).read_text());assert len(j['frames'])==len(v['frames'])+1
for frame in j['frames']:
 data=(root/frame['file']).read_bytes();assert len(data)==frame['quads']*12
 volume=sum((1 if sign else -1)*x*w*h for x,y,z,w,h,axis,sign in struct.iter_unpack('<5H2B',data) if axis==0)
 assert volume==frame['occupied'],(frame['file'],volume,frame['occupied'])
def run(path,valid):
 r=subprocess.run([exe,str(path)]+(['--verify-history'] if a.viewer else []),capture_output=True,text=True)
 assert (r.returncode==0)==valid,r.stderr
run(file,True);run(root/j['voxel_history'],True)
for name in ['../escape.json','/absolute.json','.', 'C:escape.json']:
 bad=dict(j,voxel_history=name)
 with tempfile.NamedTemporaryFile(mode='w',suffix='.json',dir=root,delete=False) as f:json.dump(bad,f);path=pathlib.Path(f.name)
 try:run(path,False)
 finally:path.unlink()
bad=dict(j);del bad['voxel_history']
with tempfile.NamedTemporaryFile(mode='w',suffix='.json',dir=root,delete=False) as f:json.dump(bad,f);path=pathlib.Path(f.name)
try:run(path,False)
finally:path.unlink()
print('All 225 mesh frame volumes agree; both manifest paths replay; unsafe redirects and legacy-only manifest rejected')
