#!/usr/bin/env python3
"""Portable CLI, deterministic workers, interval format and column-surface checks."""
import argparse, hashlib, json, math, os, struct, subprocess, sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/raydexel-test'));a=p.parse_args()
a.out.mkdir(parents=True,exist_ok=False)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve()
def run(args,valid=True):
 result=subprocess.run([str(exe),*map(str,args)],capture_output=True)
 assert (result.returncode==0)==valid,result.stderr.decode(errors='replace')
for method in ['fixed','adaptive','axis','sweep']:
 expected=None
 for workers in [1,4]:
  out=a.out/f'{method}-{workers}'
  run(['raydexel-bench','--spacing','.5','--method',method,'--workers',workers,'--out',out])
  r=json.loads((out/'report.json').read_text());m=json.loads((out/'intervals.json').read_text())
  data=(out/'intervals.bin').read_bytes();digest=hashlib.sha256(data).hexdigest()
  assert expected is None or expected==digest
  expected=digest
  assert r['operations']==1024 and r['remaining_volume_mm3']<r['initial_volume_mm3']
  assert 0<r['motion_over_removal_bound_mm']<=r['requested_motion_tolerance_mm']
  assert len(data)==m['columns']*24+m['intervals']*16
  for i in range(m['columns']):
   x,y,offset,count=struct.unpack_from('<IIQQ',data,i*24)
   spans=[struct.unpack_from('<dd',data,m['columns']*24+(offset+j)*16) for j in range(count)]
   assert all(math.isfinite(lo) and math.isfinite(hi) and lo<hi for lo,hi in spans)
   assert all(b[0]>=a[1] for a,b in zip(spans,spans[1:]))
   assert spans[0][0]==0 and spans[0][1]>=1 and spans[-1][0]<=39 and spans[-1][1]==40
   px=-6+(x+.5)*.5;py=-6+(y+.5)*.5
   if px*px+py*py<3.5**2: assert spans==[(0.,40.)], 'Retained core was damaged'
 subprocess.run([sys.executable,'scripts/export-raydexel-obj.py',str(out/'intervals.json'),str(a.out/f'{method}.obj'),'--validate-edges'],check=True)
 # Fresh-output protection must leave the saved material untouched.
 run(['raydexel-bench','--spacing','.5','--out',out],valid=False)
 assert hashlib.sha256((out/'intervals.bin').read_bytes()).hexdigest()==expected
for args in [['--workers','0'],['--workers','65'],['--method','unknown'],['--spacing','nan'],['--tolerance','0'],['--operations','0']]:
 run(['raydexel-bench',*args,'--out',a.out/'invalid'],valid=False)
print('Analytic rays: full screw, exact worker determinism, retained core/end caps, interval format, mesh volume/edge coverage and invalid options passed')
