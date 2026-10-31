#!/usr/bin/env python3
"""Native screw command, exhaustive oracle, checkpoint equality and input errors."""
import argparse, json, os, struct, subprocess, sys
from pathlib import Path

exe = Path('zig-out/bin/menkh' + ('.exe' if os.name == 'nt' else '')).resolve()
parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, default=Path('out/screw-cli-test'))
root = parser.parse_args().out
root.mkdir(parents=True, exist_ok=True)

def call(args, ok=True):
    r = subprocess.run([str(exe), *map(str, args)], capture_output=True)
    assert (r.returncode == 0) == ok, r.stderr.decode(errors='replace')
    return r

def cells(path):
    data = path.read_bytes()
    count, slots = struct.unpack_from('<QQ', data, 64)
    ds = struct.unpack_from('<' + 'I' * count, data, 96)
    pool = data[96 + 4 * count:]
    assert len(pool) == slots * 64
    return [bytes(64) if d == 0xffffffff else bytes([255]) * 64 if d == 0xfffffffe else pool[d*64:(d+1)*64] for d in ds]

out = root / 'native'
call(['grinding-demo', '--voxel', '.5', '--tolerance', '.08', '--steps-per-turn', '16', '--out', out])
job = json.loads((out / 'job.json').read_text())
protocol = json.loads((out / 'protocol.json').read_text())
assert len(job['operations']) == protocol['operations'] == 128
report = json.loads((out / 'result/report.json').read_text())
assert report['remaining_occupied'] < report['initial_occupied']
subprocess.run([sys.executable, 'scripts/check-screw-geometry.py', str(out/'result/final.menkh')], check=True)
call(['dexel-bench', '--voxel', '.5', '--tolerance', '.08', '--steps-per-turn', '16', '--check-state', out/'result/final.menkh', '--out', root/'dexel'])
dexel = json.loads((root/'dexel/report.json').read_text())
assert dexel['exact_grid_comparison'] and dexel['remaining_occupied'] == report['remaining_occupied']
assert all(o['motion_over_removal_bound_mm'] <= .08 + 1e-12 for o in report['operations'])
call(['job', out / 'job.json', '--reference', '--out', root / 'reference'])
assert cells(out / 'result/final.menkh') == cells(root / 'reference/final.menkh')
first = dict(job, operations=job['operations'][:64])
(root / 'first.json').write_text(json.dumps(first))
call(['job', root / 'first.json', '--out', root / 'first'])
second = dict(job, operations=job['operations'][64:], stock=dict(state_file=str((root/'first/final.menkh').resolve())))
(root / 'second.json').write_text(json.dumps(second))
call(['job', root/'second.json', '--out', root/'second'])
assert cells(out/'result/final.menkh') == cells(root/'second/final.menkh')
# Output protection and explicit invalid parameters.
call(['grinding-demo', '--out', out, '--generate-only'], ok=False)
for args in [['--voxel', '0'], ['--tolerance', 'nan'], ['--steps-per-turn', '1'], ['--world-grid', '16383']]:
    call(['grinding-demo', *args, '--out', root/'invalid'], ok=False)
assert not (root/'invalid').exists()
print('Native screw demo: 128 continuous cuts, exhaustive occupancy equality, resume, bounds and input failures passed')
