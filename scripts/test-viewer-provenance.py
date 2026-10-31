#!/usr/bin/env python3
"""Portable C++/Windows viewer provenance validation and negative cases."""
import argparse,copy,json,shutil,struct,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--exe',required=True);p.add_argument('--history',default='out/provenance-test/voxel-animation.json');p.add_argument('--viewer',action='store_true');a=p.parse_args()
exe=str(Path(a.exe).resolve());source=Path(a.history).resolve()
def run(path,ok):
 r=subprocess.run([exe,str(path)]+(['--verify-history'] if a.viewer else []),capture_output=True)
 assert (r.returncode==0)==ok,r.stderr.decode(errors='replace')
run(source,True)
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp)/'history';shutil.copytree(source.parent,root);header=root/'surface-provenance.json';binary=root/'surface-provenance.bin';orig=json.loads(header.read_text());raw=binary.read_bytes();path=root/source.name
 for key,value in [('grid',[1,2,3]),('scope','unknown_scope'),('entries',-1),('bytes',orig['bytes']+1),('final_occupied',orig['final_occupied']+1)]:
  bad=copy.deepcopy(orig);bad[key]=value;header.write_text(json.dumps(bad));run(path,False)
 header.write_text(json.dumps(orig))
 for offset,value in [(8,0),(8,len(orig['operations'])+1),(12,0xffffffff)]:
  bad=bytearray(raw);struct.pack_into('<I',bad,offset,value);binary.write_bytes(bad);run(path,False)
 binary.write_bytes(raw[:-1]);run(path,False)
 bad=bytearray(raw);bad[16:24]=bad[:8];binary.write_bytes(bad);run(path,False)
 binary.write_bytes(raw);run(path,True)
print('Provenance reader: valid history plus 10 malformed metadata/buffer cases passed')
