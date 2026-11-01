#!/usr/bin/env python3
"""Repeat the frozen no-history screw experiment; retain all phases and regressions."""
import argparse, hashlib, json, os, platform, statistics, subprocess, time
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--engine', type=Path, default=Path('zig-out/bin/menkh' + ('.exe' if os.name == 'nt' else '')))
p.add_argument('--workers', type=int, default=8)
p.add_argument('--repeats', type=int, default=3)
p.add_argument('--spacings', nargs='+', type=float, default=[.25, .1, .05, .025])
p.add_argument('--methods', nargs='+', choices=['fixed','adaptive','axis','sweep'], default=['fixed','adaptive'])
p.add_argument('--tolerance', type=float, default=.01)
p.add_argument('--out', type=Path, default=Path('out/raydexel-benchmark'))
a = p.parse_args()
if a.repeats < 2 or not 1 <= a.workers <= 64: p.error('require >=2 repetitions and 1..64 workers')
a.out.mkdir(parents=True, exist_ok=False)
records=[]; expected={}
env=dict(source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
         tracked_diff_sha256=hashlib.sha256(subprocess.check_output(['git','diff','HEAD'])).hexdigest(),
         binary_sha256=hashlib.sha256(a.engine.read_bytes()).hexdigest(),os=platform.platform(),
         workers=a.workers,tolerance_mm=a.tolerance,warmups=1,repeats=a.repeats,
         note='Kernel includes stock construction and worker merge. No history/provenance/viewer. Uncommitted new sources must accompany binary identity.')
env['source_sha256']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path('src').glob('*.zig'))}
(a.out/'environment.json').write_text(json.dumps(env,indent=2))
for spacing in a.spacings:
 for repeat in range(a.repeats+1):
  for method in (a.methods if repeat%2==0 else a.methods[::-1]):
   out=a.out/f'{spacing:g}-{method}-{repeat}'
   start=time.perf_counter()
   with (a.out/(out.name+'.log')).open('wb') as log:
    subprocess.run([str(a.engine.resolve()),'raydexel-bench','--spacing',str(spacing),'--method',method,'--workers',str(a.workers),'--tolerance',str(a.tolerance),'--out',str(out)],stdout=log,stderr=log,check=True)
   wall=time.perf_counter()-start
   report=json.loads((out/'report.json').read_text())
   digest=hashlib.sha256((out/'intervals.bin').read_bytes()).hexdigest()
   key=(spacing,method)
   if key not in expected: expected[key]=digest
   assert digest==expected[key], 'Non-deterministic interval endpoints'
   row=dict(spacing_mm=spacing,method=method,warmup=repeat==0,repetition=repeat,
            wall_seconds=wall,interval_sha256=digest,job_sha256=hashlib.sha256((out/'job.json').read_bytes()).hexdigest(),report=report)
   records.append(row);(a.out/'runs.json').write_text(json.dumps(records,indent=2))
   print(out.name, f"cut {report['timing']['cut_including_stock_init_ns']/1e9:.4f}s, wall {wall:.4f}s",flush=True)
summary=[]
for spacing in a.spacings:
 for method in a.methods:
  rows=[r for r in records if r['spacing_mm']==spacing and r['method']==method and not r['warmup']]
  metrics={}
  for field in ['planning_ns','hierarchy_ns','cut_including_stock_init_ns','kernel_total_ns','export_ns']:
   values=[r['report']['timing'][field]/1e9 for r in rows]
   metrics[field.removesuffix('_ns')+'_seconds']=dict(median=statistics.median(values),min=min(values),max=max(values))
  summary.append(dict(spacing_mm=spacing,method=method,workers=a.workers,metrics=metrics,
                      peak_rss_bytes=max(r['report']['peak_rss_before_export_and_oracle_bytes'] for r in rows),
                      intervals=rows[0]['report']['intervals'],interval_sha256=rows[0]['interval_sha256']))
(a.out/'summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2))
