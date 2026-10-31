#!/usr/bin/env python3
"""Compare endpoints on matching XY rays, not a certified 3D surface distance."""
import argparse
import bisect
import json
import math
import struct
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('first', type=Path)
p.add_argument('second', type=Path)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
def load(directory):
    m = json.loads((directory/'intervals.json').read_text())
    if m['format'] != 'menkh-experimental-z-rays-v1' or m['units'] != 'mm':
        raise ValueError('Unsupported interval format')
    if m['columns']*24 + m['intervals']*16 > 256*1024*1024:
        raise ValueError('Comparison input limit is 256 MiB per state')
    data = (directory/'intervals.bin').read_bytes()
    if len(data) != m['columns']*24 + m['intervals']*16:
        raise ValueError('Invalid interval file size')
    return m, data
left, lb = load(a.first)
right, rb = load(a.second)
for key in ['origin', 'spacing_mm', 'grid_xy', 'columns']:
    if left[key] != right[key]:
        raise ValueError('Requires matching rays: '+key)
maxima = [0., 0.]
maximum_context = [None, None]
difference_lengths = [0., 0.]
longest_difference = [0., 0.]
sums = [0., 0.]
counts = [0, 0]
changed = different_counts = 0
offsets = [0, 0]
previous = -1
for i in range(left['columns']):
    ends = []
    coords = []
    for k, (meta, data) in enumerate([(left, lb), (right, rb)]):
        x, y, offset, count = struct.unpack_from('<IIQQ', data, i*24)
        if offset != offsets[k] or offset+count > meta['intervals'] or x >= meta['grid_xy'][0] or y >= meta['grid_xy'][1]:
            raise ValueError('Invalid column record')
        values = list(struct.unpack_from('<'+'d'*(2*count), data, meta['columns']*24+offset*16))
        if any(not math.isfinite(v) for v in values) or any(v > w for v, w in zip(values, values[1:])) or any(values[j] >= values[j+1] for j in range(0, len(values), 2)):
            raise ValueError('Invalid intervals')
        offsets[k] += count
        ends.append(values)
        coords.append((x,y))
    if coords[0] != coords[1] or coords[0][1]*left['grid_xy'][0]+coords[0][0] <= previous:
        raise ValueError('Requires identical ordered ray coordinates')
    previous = coords[0][1]*left['grid_xy'][0]+coords[0][0]
    changed += ends[0] != ends[1]
    different_counts += len(ends[0]) != len(ends[1])
    for k in [0,1]:
        for lo, hi in zip(ends[k][::2], ends[k][1::2]):
            at = lo
            for nlo, nhi in zip(ends[1-k][::2], ends[1-k][1::2]):
                if nhi <= at: continue
                if nlo >= hi: break
                if nlo > at:
                    length = min(nlo, hi)-at
                    difference_lengths[k] += length
                    longest_difference[k] = max(longest_difference[k], length)
                at = max(at, nhi)
                if at >= hi: break
            if at < hi:
                difference_lengths[k] += hi-at
                longest_difference[k] = max(longest_difference[k], hi-at)
        for z in ends[k]:
            other = ends[1-k]
            if not other:
                raise ValueError('Unmatched empty column has no finite endpoint distance')
            j = bisect.bisect_left(other,z)
            nearest = min(abs(z-other[t]) for t in [j-1,j] if 0 <= t < len(other))
            if nearest > maxima[k]:
                maxima[k] = nearest
                maximum_context[k] = dict(ray_xy=list(coords[k]), world_xyz=[left['origin'][0]+(coords[k][0]+.5)*left['spacing_mm'],left['origin'][1]+(coords[k][1]+.5)*left['spacing_mm'],z], source_endpoints=ends[k], other_endpoints=other)
            sums[k] += nearest
            counts[k] += 1
if offsets != [left['intervals'], right['intervals']]:
    raise ValueError('Unreferenced intervals')
report = dict(first=str(a.first),second=str(a.second),spacing_mm=left['spacing_mm'],
              changed_columns=changed,columns_with_different_interval_counts=different_counts,
              directional_max_z_endpoint_difference_mm=maxima,
              directional_mean_z_endpoint_difference_mm=[s/n if n else 0 for s,n in zip(sums,counts)],
              sampled_endpoints=counts,maximum_context=maximum_context,
              directional_material_difference_mm3=[v*left['spacing_mm']**2 for v in difference_lengths],
              directional_longest_changed_z_interval_mm=longest_difference,
              note='Both directions on matching XY rays only. Differences between approximation policies, not simulation error against exact machining or a certified 3D Hausdorff bound.')
a.out.parent.mkdir(parents=True,exist_ok=True)
with a.out.open('x') as f: json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
