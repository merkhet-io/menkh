#!/usr/bin/env python3
"""Paired final-only/all-frame indexing cost, with identical material validation."""
import argparse, hashlib, json, os, statistics, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--job',type=Path,default=Path('examples/pocket-25um.json'));p.add_argument('--out',type=Path,default=Path('out/playback-pocket'));p.add_argument('--repeats',type=int,default=3);p.add_argument('--warmups',type=int,default=1);args=p.parse_args()
if args.repeats<1 or args.warmups<0:p.error('positive repeats and nonnegative warmups required')
args.out.mkdir(parents=True,exist_ok=True);records=[];exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else ''))
for scope in ['final_surface','all_frames']:
 job=json.loads(args.job.read_text());job.update(export_provenance=True,provenance_scope=scope)
 file=args.out/(scope+'.json');file.write_text(json.dumps(job));dest=args.out/scope
 for i in range(args.warmups+args.repeats):
  start=time.perf_counter();subprocess.run([str(exe),'job',str(file),'--out',str(dest)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);wall=time.perf_counter()-start
  r=json.loads((dest/'report.json').read_text())
  records.append(dict(scope=scope,warmup=i<args.warmups,wall_seconds=wall,mode=r['mode'],zig=r['zig'],cut_ns=sum(x['cut_ns'] for x in r['operations']),timing=r['timing'],process_peak_rss_bytes=r['process_peak_rss_bytes'],provenance_entries=r['provenance_entries'],provenance_capacity_bytes=r['provenance_capacity_bytes'],state_sha256=hashlib.sha256((dest/'final.menkh').read_bytes()).hexdigest()))
assert len({r['state_sha256'] for r in records})==1,'Material changed with scope or repetition'
(args.out/'measurements.json').write_text(json.dumps(records,indent=2)+'\n')
for scope in ['final_surface','all_frames']:
 r=[x for x in records if x['scope']==scope and not x['warmup']];times=[x['wall_seconds'] for x in r]
 print(f"{scope}: median wall {statistics.median(times):.6f}s, range {min(times):.6f}–{max(times):.6f}s; {r[0]['provenance_entries']} records; peak RSS {max(x['process_peak_rss_bytes'] for x in r)} bytes")
