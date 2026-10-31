#!/usr/bin/env python3
"""D3D12 smoke oracle: profile visibility and shading-only silhouette invariance."""
import argparse, json, subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--viewer', type=Path, default=Path('out/windows-viewer/menkh-viewer.exe'))
p.add_argument('--history', type=Path, default=Path('out/screw-cli-test/native/result/voxel-animation.json'))
p.add_argument('--out', type=Path, default=Path('out/windows-grinding-render'))
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
h = json.loads(a.history.read_text())
frame = max(1, len(h['frames']) // 2)

def render(name, *flags):
    path = a.out / (name + '.ppm')
    subprocess.run([str(a.viewer.resolve()), str(a.history), '--warp', '--debug',
                    '--frame', str(frame), '--snapshot', str(path), *flags], check=True)
    data = path.read_bytes()
    # Viewer writes a binary P6 header with no comments.
    magic, dimensions, maximum, pixels = data.split(b'\n', 3)
    assert magic == b'P6' and maximum == b'255'
    width, height = map(int, dimensions.split())
    assert len(pixels) == width * height * 3
    return [pixels[i:i+3] for i in range(0, len(pixels), 3)]

raw = render('face-normals', '--hide-tool')
smooth = render('smooth-lighting', '--hide-tool', '--smooth-lighting')
wheel = render('profile-wheel')
assert len(raw) == len(smooth) == len(wheel)
assert sum(a != b for a, b in zip(raw, smooth)) > 100, 'Smoothing had no visible effect'
background = raw[0]
assert [p == background for p in raw] == [p == background for p in smooth], 'Lighting changed the silhouette'
assert sum(a != b for a, b in zip(raw, wheel)) > 100, 'Recorded wheel not visible'
print('D3D12: profile wheel visible; lighting changes pixels but preserves background silhouette')
