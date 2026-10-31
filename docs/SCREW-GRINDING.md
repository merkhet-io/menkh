# Screw grinding experiment, protocol v1

Frozen before kernel changes on top of `ef49d0a67c9d81f7f4822d176e355c7c1b09b4fc`.
This is a two-start helical screw grinding workload, not an involute worm or a
certified manufacturing process. The original grinding demo remains available.

## Geometry and motion

- Cylindrical blank: diameter 12 mm, length 40 mm, base (0,0,0).
- Two starts, each four turns, 8 mm lead, wheel center Z from 4 to 36 mm.
- Wheel center radius 12 mm. Profile (axial Z, radius) in mm:
  (0,7), (0.8,8), (1.2,8), (2,7).
- A = atan(8/(2*pi*5)); C follows the helix through four complete turns.
- 128 XYZAC segments per turn, 1,024 operations in total. Each segment is a
  continuous bounded sweep, not an isolated stamp. XYZ positions interpolate
  linearly; C is unwrapped. The centerline chord error relative to the intended
  circular helix is at most 12*(1-cos(pi/128)) = 0.003615 mm.
- Motion tolerance 0.01 mm, separately from voxel spacing and chord error.
  The existing conservative profile sweep may over-remove within its reported
  motion bound. A nominal 4 mm root radius describes the path design, not a
  guaranteed finished root profile.
- Measurements: 0.1, 0.05 and 0.025 mm voxels; identical path and tolerance.
- Explicit smoke configuration: 0.25 mm, 32 segments/turn, 0.05 mm tolerance.

## Outputs and acceptance

Save checkpoints, reversible operation history, PPM, report and all-frame
surface-exposure provenance; no full mesh export. Count occupied voxels,
boundary voxels and exposed voxel faces separately. Output coloring identifies
exposure operations, not accuracy. Profile-wheel display is currently unavailable.

Compare the pre-optimization ReleaseFast binary with the new binary on the
same job. Require identical final occupancy and history material states. Keep
small-grid exhaustive subtraction as an oracle; independently test containment
bounds against tool geometry and retain existing continuous-coverage tests.
Record cutting separately from total job/export time, peak RSS, capacities,
history bytes and predicate counters. Warm up and repeat matched runs; preserve
failures. No predicate-rate or virtual-grid result implies parity with Jens.

The optional `--world-grid 16384` is a *resource probe*: a 16,384-cubed world
around the same blank. It does not enlarge the blank or improve its resolution.
The current dense descriptor backend may reject this world. A successful small
screw run does not establish 16k-cubed grinding capability.

## Native commands

Build with Zig 0.15.2, `zig build -Doptimize=ReleaseFast` (`./zig` on macOS).
The output directory must be new.

```sh
zig-out/bin/menkh grinding-demo --out out/screw
zig-out/bin/menkh grinding-demo --voxel 0.025 --out out/screw-25um
zig-out/bin/menkh grinding-demo --voxel 0.25 --steps-per-turn 32 --tolerance 0.05 --out out/screw-smoke
zig-out/bin/menkh grinding-demo --world-grid 16384 --generate-only --out out/screw-16k
```

On Windows use `zig-out\bin\menkh.exe` with the same arguments; no shell script
or Python is required. `--generate-only` writes the job and protocol without
running it. `--no-provenance` disables coloring and is a different benchmark
configuration. Open `result/voxel-animation.json` in the native viewer. On macOS:

```sh
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/screw/result/voxel-animation.json --color-operation --frame 0 --hide-tool
```

## Optimization and its boundary

Non-flat sweeps use oriented enclosing-cylinder bounds. Block rejection uses
that enclosing cylinder, never a center-only full-removal decision. A second
pass groups eight adjacent sweep pieces. For each group it inflates the first
pose by the maximum endpoint translation plus
`sqrt(radius² + length²) * |axis - first_axis|`, plus each piece's existing
motion bound and a floating-point guard. This encloses the group because a
solid of revolution can align its axis by a shortest rotation, and its signed
distance is 1-Lipschitz. The inflated pose only rejects candidates; the original
piece predicates still decide every removed voxel. Different tools disable
this optimization. Exact flat-tool paths retain their existing path.

The scalar reference retains its original bounds and exhaustive pose tests.
These new geometric rejection algorithms are **outside the Lean model**;
existing proofs, audits and bridge tests still apply only to their documented
models. Differential and independent geometry tests validate this change.
Counter totals include rejection-envelope evaluations, not just final cutter
membership tests; they are not directly comparable to Jens's kernel rate.

To repeat the matched benchmark, first save a ReleaseFast binary built before
the engine changes, then run:

```sh
python3 scripts/benchmark-screw.py --baseline /path/to/baseline-menkh --out out/screw-comparison
```

This uses one warm-up and three measured repetitions per binary, alternating
order, a fresh stock each time, binary/job SHA-256 identifiers, and byte-identical
final-state validation. It retains full reports and logs. Without `--baseline`
it measures the current binary alone. Writes are cached filesystem writes,
not a durable-storage benchmark. Use `menkh inspect-state result/final.menkh`
for allocation-free-in-the-counting-pass boundary voxel and face statistics.
