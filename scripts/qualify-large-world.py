#!/usr/bin/env python3
"""Reproduce #11 capacity failures and optionally rerun existing snapshot benchmarks.

This is a qualification report, not an implementation of large-world storage.
Calculated capacities are kept separate from measured timings and allocations.
"""
import argparse,hashlib,json,os,platform,statistics,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=ROOT/'out/large-world-qualification');p.add_argument('--tiles',action='store_true',help='Also run the 4096³ immutable-snapshot comparison (warm-up + four measurements per scene)');args=p.parse_args()
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
exe=ROOT/('zig-out/bin/menkh.exe' if os.name=='nt' else 'zig-out/bin/menkh')
# Query actual binary build metadata with a tiny successful job.
info={'version':1,'units':'mm','voxel_mm':.5,'bounds':{'lo':[0,0,0],'hi':[1,1,1]},'stock':{'primitives':[{'box':{'lo':[0,0,0],'hi':[1,1,1]}}]},'operations':[],'export_mesh':False}
(out/'binary-info.json').write_text(json.dumps(info))
subprocess.run([str(exe),'job',str(out/'binary-info.json'),'--out',str(out/'binary-info')],check=True,capture_output=True)
binary_info=json.loads((out/'binary-info/report.json').read_text())
records=[]
for n in [20000,65536]:
 size=n*.01
 # Small actual stock isolates the empty-world overhead from occupied volume.
 job={'version':1,'units':'mm','voxel_mm':.01,'bounds':{'lo':[0,0,0],'hi':[size]*3},'stock':{'primitives':[{'box':{'lo':[0,0,0],'hi':[1,1,1]}}]},'operations':[],'export_mesh':False}
 file=out/f'{n}.json';file.write_text(json.dumps(job,indent=2)+'\n')
 start=time.perf_counter()
 try:
  r=subprocess.run([str(exe),'job',str(file),'--out',str(out/str(n))],capture_output=True,text=True,timeout=30)
  status='initialization_succeeded' if r.returncode==0 else 'rejected'
  error=r.stderr.strip();code=r.returncode
 except subprocess.TimeoutExpired:
  status='timeout';error='Initialization exceeded 30 seconds';code=None
 records.append(dict(grid=[n]*3,small_stock_mm=[1]*3,status=status,exit_code=code,message=error,measured_elapsed_seconds=time.perf_counter()-start,calculated_dense_descriptor_bytes=((n+7)//8)**3*4,calculated_dense_occupancy_bit_bytes=(n**3+7)//8))
report=dict(issue=11,build_mode=binary_info['mode'],workers=binary_info['workers'],hardware=platform.machine(),platform=platform.platform(),zig=subprocess.check_output([str(ROOT/'zig'),'version'],text=True).strip(),base_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),binary_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),source_sha256={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [ROOT/'src/core.zig',ROOT/'src/tiles.zig']},probes=records,calculated_one_u32_per_2pow32_faces_bytes=2**34,note='Capacity formulas are NOT measured allocations. A successful initialization alone does not demonstrate machining, 2^32 exposed faces, or a 16 GiB working set. No memory-budget enforcement is claimed by these probes.')
if args.tiles:
 subprocess.run([str(exe),'tiles-bench',str(out/'tiles')],check=True)
 tiles=json.loads((out/'tiles/tiles.json').read_text());summary={}
 for name in sorted({r['case'] for r in tiles['samples_including_warmup']}):
  measured=[r for r in tiles['samples_including_warmup'] if r['case']==name][1:]
  summary[name]={key:{'median':statistics.median(r[key] for r in measured),'min':min(r[key] for r in measured),'max':max(r[key] for r in measured)} for key in ['dense_bytes','tiled_bytes','convert_ns','dense_query_ns','tiled_query_ns','peak_rss_bytes']}
 report['immutable_snapshot_summary']=summary
(out/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'probes':[{k:r[k] for k in ['grid','status','message']} for r in records],'report':str(out/'qualification.json')},indent=2))
