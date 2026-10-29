#!/usr/bin/env python3
"""Independent standard-library checks for the fixed example's actual exports."""
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
report_path = root / 'report.json'
report = (json.loads(report_path.read_text()) if report_path.exists()
          else json.loads((root / 'benchmark.json').read_text())['optimized']['last'])
h = report['voxel_mm']
with (root / 'height.ppm').open('rb') as f:
    assert f.readline() == b'P6\n'
    width, height = map(int, f.readline().split())
    assert f.readline() == b'255\n'
    rgb = f.read()
assert (width, height) == (round(40 / h), round(30 / h))
assert len(rgb) == width * height * 3
assert all(rgb[i] == rgb[i + 1] == rgb[i + 2] for i in range(0, len(rgb), 3))
assert set(rgb) == {153, 255}, 'Expected a 6 mm floor and 10 mm stock top'
removed_columns = rgb[::3].count(153)
assert math.isclose(removed_columns * (4 / h) * h**3, report['removed_volume_mm3'], abs_tol=1e-8)

# Exporter writes four independent vertices directly before each quad.
# Oriented boundary integral independently verifies watertight volume + face winding.
vertices = []
faces = 0
volume_terms = []
with (root / 'surface.obj').open() as f:
    for line in f:
        fields = line.split()
        if not fields:
            continue
        if fields[0] == 'v':
            p = tuple(map(float, fields[1:]))
            assert len(p) == 3 and all(math.isfinite(x) for x in p)
            assert all(-1e-8 <= x <= bound + 1e-8 for x, bound in zip(p, (40, 30, 10)))
            vertices.append(p)
        elif fields[0] == 'f':
            face = [vertices[int(i) - 1] for i in fields[1:]]
            assert len(face) == 4
            p, q, _, r = face
            u = [q[i] - p[i] for i in range(3)]
            v = [r[i] - p[i] for i in range(3)]
            normal = (u[1]*v[2] - u[2]*v[1], u[2]*v[0] - u[0]*v[2], u[0]*v[1] - u[1]*v[0])
            volume_terms.append(sum(p[i]*normal[i] for i in range(3)) / 3)
            faces += 1
volume = math.fsum(volume_terms)
assert faces == report['quads']
assert math.isclose(volume, report['occupied_volume_mm3'], abs_tol=1e-6), (volume, report['occupied_volume_mm3'])
print(f'{root}: PPM validated; {faces} OBJ quads; oriented volume {volume:.9f} mm³')
