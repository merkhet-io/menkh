# Imported ball finishing experiment — protocol v1

Frozen before optimization, baseline source `18f115165aedc3367962f706f248379e8a1c60d5`,
Zig 0.15.2, ReleaseFast, one CPU cutting worker. Debug is used for tests.
Machine: Apple M5 Max, 18 cores, 128 GiB unified memory, macOS. Baseline executable
is retained in `out/finishing-baseline/menkh`; record its hash with every comparison.
No pushes, merges or releases are part of this milestone.

## B: imported insert

Domain 24 × 16 × 10 mm, translated by (0.013, -0.017, 0.009) mm.
A closed, outward-oriented binary STL height-field solid over a flat bottom is
procedurally generated on a 0.125 mm XY lattice. The target height is
6 + 0.7 cos(x/4) cos(y/3) - 1.4 exp(-((x-8)/3)^2-((y-6)/2)^2)
- 1.1 exp(-((x-17)/2.5)^2-((y-11)/2)^2)
+ 0.65 exp(-((y-8)/0.25)^2) mm. This produces two curved pockets and a narrow rib.
Stock uses the same surface plus 0.8 mm: a pre-roughed small insert, not a billet
roughing benchmark. Stock and target share neither occupancy nor surface height.
Both are imported independently. The generator is original project code (no third-party geometry).

Ball end mill: radius 1 mm, total cutting length 5 mm, fixed +Z orientation;
hemisphere plus finite cylindrical flute. Shank radius 0.8, length 2, offset 5;
holder radius 2, length 2, offset 7 mm. No fixtures in this protocol: fixture
checks are explicitly not applicable; shank/holder-stock checks remain enabled.

Path: 80 serpentine passes at 0.2 mm stepover, x=0..24, 64 segments/pass,
plus inter-pass links (5,199 segments). Tip heights are generated from a sampled
ball-contact envelope: maximum of target(x+dx,y+dy)+sqrt(1-dx²-dy²)-1
on a 0.1 mm disk lattice, plus 0.03 mm allowance. This is an explicit example
path, not certified collision-free CAM. Stepover scallops, sampled envelope and
linear interpolation may create excess or gouges: report them as path effects.
No rapid traverse through stock is hidden or omitted.

## A: independent accuracy fixture

A ball traverses a straight tilted line across a cuboid, with tip height rising
from 2.137 to 5.137 mm over 6 mm X. A second constant-height line supplies a flat
region. Radius 1, flute length 5. XY offset (0.113,0.071), stock origin offset
(0.013,-0.017,0.009). Cross-sections contain flat, spherical and steep side regions.
The independent oracle uses time intervals for the swept upper cylinder and
lower hemisphere, not production SDF code. Compare occupancy and sampled boundary
points to continuous motion; distance samples are estimates, not Hausdorff bounds.

## Resolution, output and resource budget

Run A at 0.25, 0.1, 0.05, 0.025 mm; motion tolerance 0.005 mm, plus 0.001 mm
sensitivity. B uses the same spacings and 0.005 mm tolerance. Smoke B uses 0.25 mm
and the identical stock/target/path; it is explicitly a smaller *grid*, not a
simplified part. Full B at 25 µm has 245,760,000 addressable centers.

Retain binary states, target buffers, reversible deltas, reports, height images
and critical sections. No full OBJ is required for B: direct voxel rendering is
the inspection path. Mesh export remains tested by the existing varied suite.
Warm-up plus two measured repetitions from identical stock for performance;
use medians and min/max. Baseline full case: timeout 120 s per attempt; optimized
case: 900 s per attempt. Limit planned outputs to 8 GiB and process RSS to 16 GiB;
report violations, never silently reduce the frozen workload. No durable-I/O claim.

## Acceptance and measurements

- Optimized STL occupancy exactly equals the scalar importer on small rotated,
  concave, cavity, disconnected, thin and boundary fixtures. Surface AABB overlap
  may conservatively reject block filling; midpoint classification is allowed only
  after proving no surface triangle can intersect the connected center-box.
- Ball acceleration preserves the existing sampled/dilated predicate. Keep scalar
  pose enumeration. Independently validate complete ball geometry and continuous
  coverage. Report dilation (<= declared tolerance) separately from voxelization.
- Full, midpoint checkpoint/resume and compacted resume have identical represented
  bits. Full forward/backward/forward replay restores exact descriptors and live
  initial pool words; unreferenced future pool tails need not be zeroed on rewind.
- Record read, validation, BVH, voxelization, cutting, collision, statistics,
  checkpoint/history, image/surface export separately; retain counters and capacities.
- Report target excess/missing separately from analytic simulation error and input
  tessellation sampling error. Check the rib explicitly, not just aggregate volume.
- Inspect native Metal screenshots of final result and sections; report loading,
  seeking and GPU command durations without calling them interactive FPS.
- Existing Debug/ReleaseFast tests, varied suite and Lean audits/bridge remain green.
  New mesh/sweep optimizations are outside the formal implementation proof scope.

If a baseline times out, preserve its log and timeout record. Report full-case
failure distinctly from smoke success. Any later protocol amendment is versioned
and must not replace unfavorable results.

## Validation additions (workload unchanged)

The full imported case also receives a single 0.001 mm tolerance sensitivity run.
This is an additional diagnostic, not substituted for the frozen 0.005 mm timing
comparison. Original geometry, path density and unfavorable baseline results remain.
