#!/usr/bin/env python3
"""Paired whole-job comparison against a supplied earlier executable."""
import argparse, gzip, hashlib, importlib.util, json, pathlib, statistics, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('workflow', ROOT / 'scripts/finishing-workflow.py')
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=pathlib.Path, required=True)
    parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'out/import-cache')
    args = parser.parse_args()
    out = args.out.resolve()
    workflow.fixture.generate(out / 'fixture', .025)
    job = json.loads((out / 'fixture/job.json').read_text())
    executables = {'before': args.before.resolve(), 'after': ROOT / 'zig-out/bin/menkh'}
    records = []
    expected = None
    expected_buffers = None
    identity = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'note': 'Working-tree hashes identify the measured sources; one warmup and two measured runs per binary, alternating order.',
                'binary_sha256': {k: hashlib.sha256(v.read_bytes()).hexdigest() for k, v in executables.items()},
                'after_source_sha256': {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in (ROOT / 'src').glob('*.zig')},
                'job_sha256': hashlib.sha256((out / 'fixture/job.json').read_bytes()).hexdigest(),
                'mode': 'ReleaseFast', 'workers': 1, 'zig': subprocess.check_output([str(ROOT/'zig'), 'version'], text=True).strip()}
    workflow.write(out / 'identifiers.json', identity)
    for iteration in range(3):
        for name in (['before', 'after'] if iteration % 2 == 0 else ['after', 'before']):
            dest = out / f'{name}-{iteration}'
            report = workflow.execute(executables[name], job, dest)
            digest = workflow.inspection.digest(dest / 'final.menkh')
            expected = expected or digest
            assert digest == expected, 'Occupancy changed'
            buffers = {f: hashlib.sha256((dest / f).read_bytes()).hexdigest() for f in ['initial.blocks', 'initial.pool', 'target.blocks', 'target.pool']}
            expected_buffers = expected_buffers or buffers
            assert buffers == expected_buffers, 'Imported stock or target changed'
            records.append(dict(binary=name, warmup=iteration==0, report=report, occupancy_sha256=digest, imported_buffer_sha256=buffers))
            (out / 'raw.json.gz').write_bytes(gzip.compress(json.dumps(records).encode(), mtime=0))
            print(f'{name} {iteration}: {report["wall_s"]:.3f}s, RSS {report["process_peak_rss_bytes"]}', flush=True)
    summary = {'occupancy_sha256': expected, 'warmups_per_binary': 1, 'repeats_per_binary': 2}
    for name in executables:
        rows = [r['report'] for r in records if r['binary']==name and not r['warmup']]
        def stat(values):
            return dict(min=min(values), median=statistics.median(values), max=max(values))
        summary[name] = {'wall_s': stat([r['wall_s'] for r in rows]),
                         'voxelization_s': stat([(r['timing']['stock_input']['voxelization_ns']+r['timing']['auxiliary_input']['voxelization_ns'])/1e9 for r in rows]),
                         'cut_s': stat([sum(o['cut_ns'] for o in r['operations'])/1e9 for r in rows]),
                         'peak_rss_bytes': max(r['process_peak_rss_bytes'] for r in rows),
                         'stock_ray_cache_bytes': rows[0]['timing']['stock_input'].get('ray_cache_bytes', 0),
                         'stock_scanlines': rows[0]['timing']['stock_input'].get('scanlines', 0),
                         'stock_scanline_fallbacks': rows[0]['timing']['stock_input'].get('scanline_fallbacks', 0),
                         'stock_scanline_scratch_bytes': rows[0]['timing']['stock_input'].get('scanline_scratch_bytes', 0),
                         'cache_build_s': stat([(r['timing']['stock_input'].get('ray_cache_ns',0)+r['timing']['auxiliary_input'].get('ray_cache_ns',0))/1e9 for r in rows])}
    workflow.write(out / 'summary.json', summary)
    print(json.dumps(summary, indent=2))

if __name__ == '__main__':
    main()
