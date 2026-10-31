#!/usr/bin/env python3
"""Alternate two fixed-semantics binaries; validate every final interval byte."""
import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--before', type=Path, required=True)
p.add_argument('--after', type=Path, default=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')))
p.add_argument('--out', type=Path, required=True)
p.add_argument('--workers', type=int, default=8)
p.add_argument('--repeat', type=int, default=3)
p.add_argument('--spacings', type=float, nargs='+', default=[.25, .1, .05, .025])
a = p.parse_args()
if a.repeat < 1 or not 1 <= a.workers <= 64:
    p.error('Positive repeats and 1..64 workers required')
a.out.mkdir(parents=True, exist_ok=False)
binaries = {name: path.resolve() for name, path in [('before', a.before), ('after', a.after)]}
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
environment = dict(platform=platform.platform(), machine=platform.machine(), workers=a.workers,
                   warmups_per_configuration=1, repetitions=a.repeat,
                   commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                   source_diff_sha256=hashlib.sha256(subprocess.check_output(['git', 'diff'])).hexdigest(),
                   binaries={k: dict(path=str(v), sha256=sha(v)) for k, v in binaries.items()})
(a.out/'environment.json').write_text(json.dumps(environment, indent=2)+'\n')
records = []
for spacing in a.spacings:
    expected = None
    expected_job = None
    for rep in range(a.repeat+1):
        order = ['before', 'after'] if rep % 2 == 0 else ['after', 'before']
        for name in order:
            out = a.out/f'{spacing:g}-{rep}-{name}'
            subprocess.run([str(binaries[name]), 'raydexel-bench', '--spacing', str(spacing),
                            '--workers', str(a.workers), '--out', str(out)], check=True)
            digest = sha(out/'intervals.bin')
            job = sha(out/'job.json')
            if expected is None:
                expected, expected_job = digest, job
            assert digest == expected, f'Changed material: {out}'
            assert job == expected_job, f'Changed workload: {out}'
            report = json.loads((out/'report.json').read_text())
            records.append(dict(variant=name, repetition=rep, warmup=rep == 0, spacing_mm=spacing,
                                interval_sha256=digest, job_sha256=job, report=report))
            (a.out/'runs.json').write_text(json.dumps(records, indent=2)+'\n')
summary = []
for spacing in a.spacings:
    row = dict(spacing_mm=spacing)
    for name in binaries:
        selected = [r['report'] for r in records if not r['warmup'] and r['spacing_mm']==spacing and r['variant']==name]
        samples = [r['timing']['cut_including_stock_init_ns']/1e9 for r in selected]
        row[name] = dict(cut_median_s=statistics.median(samples), cut_min_s=min(samples), cut_max_s=max(samples),
                         kernel_median_s=statistics.median(r['timing']['kernel_total_ns']/1e9 for r in selected),
                         peak_kernel_rss_bytes=max(r['peak_rss_before_export_and_oracle_bytes'] for r in selected),
                         work=selected[0]['work'])
    row['cut_speedup'] = row['before']['cut_median_s']/row['after']['cut_median_s']
    summary.append(row)
(a.out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary, indent=2))
