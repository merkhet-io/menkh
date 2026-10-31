#!/usr/bin/env python3
"""Matched screw-grinding benchmark. Every repetition starts from the same stock."""
import argparse, hashlib, json, os, statistics, subprocess, time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--engine', type=Path, default=Path('zig-out/bin/menkh' + ('.exe' if os.name == 'nt' else '')))
p.add_argument('--baseline', type=Path)
p.add_argument('--voxel', type=float, default=.1)
p.add_argument('--repeats', type=int, default=3)
p.add_argument('--out', type=Path, default=Path('out/screw-benchmark'))
a = p.parse_args()
if a.repeats < 2:
    p.error('use at least two measured repetitions')
a.out.mkdir(parents=True, exist_ok=False)
engines = {'optimized': a.engine.resolve()}
if a.baseline:
    engines = {'baseline': a.baseline.resolve(), **engines}
subprocess.run([str(a.engine.resolve()), 'grinding-demo', '--generate-only', '--voxel', str(a.voxel), '--out', str(a.out/'workload')], check=True)
job = a.out/'workload/job.json'
records = []
expected = None
for i in range(a.repeats + 1):
    # Alternate ordering to reduce persistent first/last-engine bias.
    for label, engine in (list(engines.items()) if i % 2 == 0 else list(engines.items())[::-1]):
        out = a.out/f'{label}-{i}'
        start = time.perf_counter()
        with (a.out/f'{label}-{i}.log').open('wb') as log:
            subprocess.run([str(engine), 'job', str(job), '--out', str(out)], stdout=log, stderr=log, check=True)
        elapsed = time.perf_counter() - start
        report = json.loads((out/'report.json').read_text())
        digest = hashlib.sha256((out/'final.menkh').read_bytes()).hexdigest()
        # Stronger than occupancy equality here: this optimization preserves pool layout.
        if expected is None:
            expected = digest
        assert digest == expected, 'final state changed'
        record = dict(engine=label, warmup=i == 0, repetition=i, wall_seconds=elapsed,
                      total_seconds=report['timing']['total_ns']/1e9,
                      cut_seconds=sum(o['cut_ns'] for o in report['operations'])/1e9,
                      point_pose_evaluations=sum(o['work']['point_pose_evaluations'] for o in report['operations']),
                      voxel_tests=sum(o['work']['voxel_tests'] for o in report['operations']),
                      peak_rss_bytes=report['process_peak_rss_bytes'], final_sha256=digest,
                      remaining_occupied=report['remaining_occupied'], history_bytes=report['history_bytes'],
                      timing=report['timing'],
                      candidate_blocks=sum(o['work']['candidate_blocks'] for o in report['operations']),
                      partial_blocks=sum(o['work']['partial_blocks'] for o in report['operations']),
                      sweep_pieces=sum(o['sweep_pieces'] for o in report['operations']),
                      motion_bound_mm=max(o['motion_over_removal_bound_mm'] for o in report['operations']),
                      scratch_bytes=report['cut_scratch_capacity_bytes'],
                      provenance_capacity_bytes=report['provenance_capacity_bytes'],
                      stats=report['stats'])
        records.append(record)
        (a.out/'runs.json').write_text(json.dumps(records, indent=2))
        print(label, i, f'{elapsed:.3f}s', flush=True)
summary = dict(voxel_mm=a.voxel, repeats=a.repeats, warmups=1, workers=1,
               job_sha256=hashlib.sha256(job.read_bytes()).hexdigest(),
               binary_sha256={k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in engines.items()}, results={})
for label in engines:
    rows = [r for r in records if r['engine'] == label and not r['warmup']]
    summary['results'][label] = {metric:dict(median=statistics.median(r[metric] for r in rows), min=min(r[metric] for r in rows), max=max(r[metric] for r in rows)) for metric in ['wall_seconds','total_seconds','cut_seconds','peak_rss_bytes']}
(a.out/'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
