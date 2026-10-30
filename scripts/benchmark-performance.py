#!/usr/bin/env python3
"""Repeated CLI measurements, retained raw phase samples and exact-state hashes."""
import argparse, datetime, hashlib, json, pathlib, platform, statistics, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--exe', required=True)
p.add_argument('--job', required=True)
p.add_argument('--out', required=True)
p.add_argument('--repeats', type=int, default=7)
p.add_argument('--voxel', type=float)
p.add_argument('--no-mesh', action='store_true')
a = p.parse_args()
if a.repeats < 3: p.error('at least three measured repetitions required')
exe = (ROOT/a.exe).resolve(); job = (ROOT/a.job).resolve(); output = ROOT/a.out
run_dir = ROOT/'out/performance'/output.stem
if a.voxel is not None or a.no_mesh:
    specification = json.loads(job.read_text())
    if a.voxel is not None: specification['voxel_mm'] = a.voxel
    if a.no_mesh: specification['export_mesh'] = False
    job = ROOT/'out/performance/jobs'/(output.stem+'.json')
    job.parent.mkdir(parents=True, exist_ok=True)
    job.write_text(json.dumps(specification, indent=2)+'\n')
raw = []; expected = None
for rep in range(a.repeats+1):
    start = time.perf_counter_ns()
    subprocess.run([str(exe), 'job', str(job), '--out', str(run_dir)], check=True, capture_output=True)
    wall = time.perf_counter_ns()-start
    r = json.loads((run_dir/'report.json').read_text())
    digest = hashlib.sha256((run_dir/'final.menkh').read_bytes()).hexdigest()
    assert sum(x['removed_voxels'] for x in r['operations']) == r['initial_occupied']-r['remaining_occupied']
    if expected is None: expected = digest
    assert digest == expected
    sample = dict(warmup=rep==0, wall_ns=wall, total_ns=r['timing']['total_ns'],
                  cut_ns=sum(x['cut_ns'] for x in r['operations']),
                  collision_ns=sum(x['collision_ns'] for x in r['operations']),
                  surface_ns=r['timing']['surface_ns'], init_ns=r['timing']['init_ns'],
                  history_ns=sum(x['history_write_ns'] for x in r['operations']),
                  export_ns=r['timing']['export_ns'], peak_rss_bytes=r['process_peak_rss_bytes'])
    raw.append(sample)
    print(output.stem, rep, f"cut {sample['cut_ns']/1e6:.3f}ms collision {sample['collision_ns']/1e6:.3f}ms wall {wall/1e6:.3f}ms", flush=True)
summary = {k:dict(median=statistics.median(s[k] for s in raw[1:]), min=min(s[k] for s in raw[1:]), max=max(s[k] for s in raw[1:])) for k in raw[0] if k!='warmup'}
meta = dict(date=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True)),
            hardware=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
            logical_cpus=subprocess.check_output(['sysctl','-n','hw.logicalcpu'],text=True).strip(),
            os=platform.platform(), zig=r['zig'], mode=r['mode'], workers=r['workers'],
            executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
            job_sha256=hashlib.sha256(job.read_bytes()).hexdigest(), voxel_mm=r['voxel_mm'],
            segments=len(r['operations']), initial=r['initial_occupied'], remaining=r['remaining_occupied'],
            state_sha256=expected, stats=r['stats'], history_bytes=r['history_bytes'],
            cut_scratch_capacity_bytes=r.get('cut_scratch_capacity_bytes',0),
            warmups=1,repeats=a.repeats,raw=raw,summary=summary)
output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps(meta,indent=2)+'\n')
