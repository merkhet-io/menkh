#!/usr/bin/env python3
"""Matched live-publication overhead. Full warm-up per mode, identical fresh stocks."""
import argparse, hashlib, json, os, platform, statistics, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--job',type=Path,default=Path('out/live-demo-job.json'));p.add_argument('--out',type=Path,default=Path('out/live-benchmark'));p.add_argument('--repeats',type=int,default=3);args=p.parse_args()
assert args.repeats>=1
root=args.out.resolve();root.mkdir(parents=True,exist_ok=True)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve();job=json.loads(args.job.read_text());source=hashlib.sha256(args.job.read_bytes()).hexdigest()
records=[];expected=None
for warm in [True,False]:
 for repeat in range(1 if warm else args.repeats):
  for mode in ['archive','live']:
   config=dict(job)
   if mode=='archive':config.pop('live_inspection',None)
   else:config['live_inspection']=dict(config.get('live_inspection',{}),start_paused=False)
   name=f'{mode}-'+('warmup' if warm else str(repeat));file=root/(name+'.json');file.write_text(json.dumps(config))
   dest=root/name
   if dest.exists():raise RuntimeError(f'Use a fresh output: {dest}')
   start=time.perf_counter()
   with (root/(name+'.log')).open('w') as log:
    subprocess.run([str(exe),'job',str(file),'--out',str(dest)],check=True,stdout=log,stderr=log)
   wall=time.perf_counter()-start;r=json.loads((dest/'report.json').read_text());digest=hashlib.sha256((dest/'final.menkh').read_bytes()).hexdigest()
   if expected is None:expected=digest
   assert expected==digest
   record=dict(mode=mode,warmup=warm,repeat=repeat,wall_seconds=wall,job_seconds=r['timing']['total_ns']/1e9,cut_seconds=sum(op['cut_ns'] for op in r['operations'])/1e9,peak_rss_bytes=r['process_peak_rss_bytes'],history_bytes=r['history_bytes'],cut_scratch_capacity_bytes=r['cut_scratch_capacity_bytes'],live=r['live_publication'],final_state_sha256=digest)
   records.append(record);(root/'raw.json').write_text(json.dumps(records,indent=2));print(name,round(wall,3),'s',flush=True)
summary={}
for mode in ['archive','live']:
 rows=[r for r in records if r['mode']==mode and not r['warmup']]
 summary[mode]={k:dict(median=statistics.median(r[k] for r in rows),min=min(r[k] for r in rows),max=max(r[k] for r in rows)) for k in ['wall_seconds','job_seconds','cut_seconds','peak_rss_bytes']}
metadata=dict(platform=platform.platform(),commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),source_sha256=source,binary_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),compiler='Zig 0.15.2',build_mode='ReleaseFast',workers=1,operations=len(job['operations']),voxel_mm=job['voxel_mm'],summary=summary,note='Local cached writes; no durable-storage or interactive-FPS claim. Commit is base; binary and job hashes identify tested working tree.')
(root/'summary.json').write_text(json.dumps(metadata,indent=2));print(json.dumps(metadata,indent=2))
