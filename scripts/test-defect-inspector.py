#!/usr/bin/env python3
"""Generate/validate defect findings from existing jobs; optionally validate native navigation."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--result', type=Path, help='Existing clamped or general-job output directory')
    p.add_argument('--job', type=Path, help='Source job (default: RESULT/job.json)')
    p.add_argument('--viewer', action='store_true', help='Build native viewer, validate selections and save snapshots')
    args = p.parse_args()
    result = args.result
    if result is None:
        run('python3', 'scripts/clamped-finishing.py', '--voxel', '0.25', '--skip-build', '--out', 'out/defect-smoke')
        result = ROOT / 'out/defect-smoke/unsafe'
    result = result.resolve()
    job = (args.job or result / 'job.json').resolve()
    exe = ROOT / 'zig-out/bin/menkh'
    run(exe, 'inspect-defects', job, result / 'final.menkh', result)
    run(exe, 'inspect-defects', job, result / 'final.menkh', result / 'reinspect')
    assert (result / 'defects.json').read_bytes() == (result / 'reinspect/defects.json').read_bytes()
    defects = json.loads((result / 'defects.json').read_text())
    report = json.loads((result / 'report.json').read_text())
    for kind in ('excess', 'missing'):
        assert sum(r['voxels'] for r in defects['regions'] if r['kind'] == kind) == report['target_comparison'][kind]
    assert all(r['operation'] is None for r in defects['regions'])
    if args.viewer:
        run('./scripts/build-viewer.sh')
        viewer = ROOT / 'zig-out/bin/menkh-viewer'
        history = result / 'voxel-animation.json'
        run(viewer, history, '--validate-findings', '--list-findings', result / 'findings.json')
        findings = json.loads((result / 'findings.json').read_text())
        events = sum(c['occupied_centers'] > 0 or c.get('clearance') == 'unresolved_voxel_contact'
                     for op in report['operations']
                     for c in (op[k] for k in ('shank_stock', 'holder_stock', 'shank_fixture', 'holder_fixture', 'cutter_fixture')))
        assert len(findings) == len(defects['regions']) + events
        for name, select in [('missing', lambda f: f['title'].startswith('Missing')),
                             ('collision', lambda f: 'Holder / fixture' in f['title'] and 'contact' in f['title']),
                             ('unresolved', lambda f: 'unresolved' in f['title'])]:
            chosen = next((f for f in findings if select(f)), None)
            if chosen:
                run(viewer, history, '--finding', chosen['index'], '--snapshot', result / (name + '.png'))
        # A mismatched report must fail visibly, not navigate unrelated geometry.
        with tempfile.TemporaryDirectory(dir=result) as tmp:
            tmp = Path(tmp)
            for file in result.iterdir():
                if file.is_file() and file.name != 'defects.json':
                    (tmp / file.name).symlink_to(file)
            bad = dict(defects, grid=[1, 1, 1])
            (tmp / 'defects.json').write_text(json.dumps(bad))
            rejected = subprocess.run([str(viewer), str(tmp / history.name), '--list-findings', str(tmp / 'list.json')], cwd=ROOT, capture_output=True, text=True)
            assert rejected.returncode != 0 and 'Defects do not match history' in rejected.stderr
        assert all(f['frame'] == len(report['operations']) for f in findings[:len(defects['regions'])])
    print(f"Validated {len(defects['regions'])} regions: counts, saved-state regeneration" + (', native selections and snapshots' if args.viewer else ''))

if __name__ == '__main__':
    main()
