#!/usr/bin/env python3
"""Check the distributed ZIP, including real color rendering from extracted files."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from zipfile import ZipFile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--zip', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--render', action='store_true')
a = p.parse_args()
root = a.out.resolve()
root.mkdir(parents=True, exist_ok=False)
with ZipFile(a.zip) as archive:
    for name in archive.namelist():
        assert (root / name).resolve().is_relative_to(root), 'Unsafe archive path'
    archive.extractall(root)
history = root / 'demo/voxel-animation.json'
h = json.loads(history.read_text())
meta = json.loads((root / 'demo/surface-provenance.json').read_text())
assert meta['scope'] == 'all_frames'
assert meta['entries'] > 0
assert (root / 'demo/surface-provenance.bin').stat().st_size == meta['bytes'] == meta['entries'] * 16
assert len(meta['operations']) == len(h['frames'])
assert '--color-operation --frame 0' in (root / 'open-demo.bat').read_text()
assert '--color-operation' in (root / 'open-colors.bat').read_text()
job = json.loads((root / 'demo/job.json').read_text())
assert job['export_provenance'] and job['provenance_scope'] == 'all_frames'
assert '--color-operation' in (root / 'calculate-demo.bat').read_text()
if a.render:
    assert os.name == 'nt', 'Native D3D12 rendering requires Windows'
    images = root / 'images'
    images.mkdir()
    exe = str(root / 'menkh-viewer.exe')
    for label, frame in [('middle', len(h['frames']) // 2), ('final', len(h['frames']))]:
        paths = []
        for mode in ['material', 'operation', 'tool']:
            image = images / f'{label}-{mode}.ppm'
            command = [exe, str(history), '--warp', '--debug', '--frame', str(frame), '--snapshot', str(image)]
            if mode != 'material':
                command += [f'--color-{mode}']
            result = subprocess.run(command, capture_output=True, timeout=90)
            assert result.returncode == 0, result.stderr.decode(errors='replace')
            assert b'D3D12: ' not in result.stderr, result.stderr.decode(errors='replace')
            paths.append(image)
        assert paths[0].read_bytes() != paths[1].read_bytes(), f'{label}: operation colors absent'
        assert paths[0].read_bytes() != paths[2].read_bytes(), f'{label}: tool colors absent'
        assert paths[1].read_bytes() != paths[2].read_bytes(), f'{label}: operation/tool modes identical'
print('Extracted package includes playback colors and color launchers; native rendering:', a.render)
