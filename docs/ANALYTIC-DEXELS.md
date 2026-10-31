# Continuous ray-interval grinding experiment

This is an executable alternative architecture, separate from the production
voxel simulator. It processes the complete subtractive job as a union and stores
continuous Z intervals on sampled XY rays. It does not update a voxel for every
position along Z, generate per-operation history, or pretend to be a tri-dexel
implementation. The existing demos and job backend remain available.

The [frozen protocol](ANALYTIC-DEXEL-PROTOCOL.md) uses the same 12 × 40 mm screw,
1,024 continuous XYZAC segments and 0.01 mm motion budget. Actual repeated
[measurements, regressions and inspected images](evidence/analytic-dexels/README.md)
are retained. On the measured M5 Max, the fixed method takes 9.10 s median cutting
at 25 µm with eight workers. This is a no-history kernel measurement, not an
end-to-end replacement for the production demo or a comparison with Jens's
unspecified 0.3-second workload.

## Run and inspect

Zig 0.15.2; no new engine dependency or global installation:

```sh
./zig build -Doptimize=ReleaseFast
zig-out/bin/menkh raydexel-bench --spacing 0.025 --workers 8 --out out/rays-25um
# Smaller complete-path smoke configuration:
zig-out/bin/menkh raydexel-bench --spacing 0.25 --workers 4 --out out/rays-smoke
# Explicit alternate algorithm, same requested motion budget:
zig-out/bin/menkh raydexel-bench --spacing 0.025 --workers 8 --method adaptive --out out/rays-adaptive
```

On Windows use `.\zig.ps1 build -Doptimize=ReleaseFast` and
`.\zig-out\bin\menkh.exe` with the same arguments. Output directories must be
new. `--operations N` explicitly selects a path prefix; `--tolerance MM` changes
the motion budget. `--check-state FILE` compares every raster center against a
production checkpoint with matching origin/spacing. It reports disagreements in
both directions rather than asserting identical semantics.

A single build-and-run command is `./zig build raydexel-bench -Doptimize=ReleaseFast -- --spacing 0.025 --workers 8 --out out/rays-new`.

Outputs are a versioned continuous-interval dump, a JSON phase/counter report,
the exact generated job, and PPM XZ sections at Y≈0 and Y≈3 mm. The sections sample
the nearest ray row; they are not interpolated smooth surfaces. There is no native
interval-history loader, animation, operation engagement or resume in this experiment.

A Python-standard-library exporter produces an inspectable column-solid OBJ:

```sh
python3 scripts/export-raydexel-obj.py out/rays-smoke/intervals.json out/rays-smoke.obj --validate-edges
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/rays-smoke.obj --hide-path
```

Validate a saved dump without generating a mesh with `python3 scripts/inspect-raydexels.py out/rays-25um/intervals.json --check-screw-invariants`.

Use the existing macOS OBJ viewer to rotate/zoom/reset. It now fits actual mesh
bounds. `--hide-path` hides the unrelated legacy groove annotation. Windows CLI
cross-build is tested, but the Windows viewer does not yet load this interval
format or these OBJ exports. Do not point it at `intervals.json` as if it were
production voxel history. Full high-resolution mesh export can dominate time
and memory; the exporter explicitly limits input to 256 MiB. The default PPM and
interval exports do not require Python.

## What changes structurally

1. **Analytic tool/ray intervals.** A convex piecewise-linear radius profile is
   the intersection of an axial slab and conic inequalities. Intersect each
   constraint with a ray using linear/quadratic roots. Waisted/nonconvex profiles
   are rejected, not silently replaced with their convex hull.
2. **Whole-job geometry.** A spatial hierarchy groups nearby tool poses. Splits
   use pose-center extent, not the large wheel's bounding-box extent. A conservative
   oriented envelope rejects groups against surviving material intervals.
3. **Boundary preparation.** Widely spaced prepared poses seed the removed
   union before the fixed solver refines it. This reorders the same union; it does
   not omit intervening poses. Subtracting already covered regions requires no
   voxel subdivision.
4. **Independent rays.** One worker team per complete job owns disjoint row
   ranges. A deterministic merge preserves continuous endpoints byte for byte
   across worker counts. It does not spawn a new team for every cut.
5. **Continuous longitudinal state.** Column/interval storage scales with sampled
   transverse area and interval complexity, not a dense XYZ descriptor array.
   Long empty/full Z ranges are one interval. This does not prove optimal
   surface-only complexity or make ray count independent of resolution.

The original quantized dexel experiment recursively applied generic shape
predicates and rewrote its complete pool twice per operation. Merely changing
storage had been slower. This implementation changes how geometry is evaluated.

## Motion and approximation contract

All tools are solids of revolution with a convex radius profile and positive
cap radii. Rotary XYZAC positions refer to the tool center as in the existing
grinding job. Coordinates and intervals are local workpiece millimeters; f64
geometry is retained. Other tool families/stock geometries are not accepted by
this experiment's CLI.

For side radius `r = b + m*z`, an outward plane offset `delta` gives
`r <= b + m*z + delta*sqrt(1+m*m)`. Axial caps move outward by `delta`. This
intersection contains the Euclidean offset but can be larger at corners. In the
meridional convex polygon, a corner between outward normals separated by angle
`theta` moves at most `delta / cos(theta/2)`. The maximum factor over adjacent
sides/caps is reported (1.1095045 for this wheel). Revolving the meridional bound
preserves Euclidean point distance. Offset sides that become redundant do not
increase the bound. Profiles requiring a factor above eight are rejected.

**Fixed method (default):** bounded rotary segments become inflated midpoint
poses. Translation half-gap and rotation displacement are included in their
outward offsets; the planner reduces its internal tolerance to pay for the miter
factor. The frozen workload's reported bound is 0.00847741 mm. This is continuous
coverage with possible bounded over-removal, not unconnected pose stamping.
Its semantics differ from the production union of Euclidean-offset endpoint
poses, so the final occupancy is not asserted to be identical.

**Adaptive method:** precompute a temporal hierarchy of true-time midpoint
poses with displacement envelopes. On each ray, undilated true tool intervals
serve as witnesses. An outer interval may be accepted when it lies within the
requested Z-distance of their union; that also bounds its Euclidean distance to
actual swept material. Approximate accepted intervals never become witnesses,
so successive acceptance cannot accumulate the error. Otherwise refine time,
or accept a leaf whose full 3D offset bound fits the requested tolerance. This
method is currently slower on the frozen screw and remains explicitly selectable.
Its coarser acceptance can differ from exhaustive fine-leaf occupancy; it is
validated against independent geometry and its declared bound, not advertised
as an exact rewrite of the fixed solver. Reordering an approximate hierarchy is
not promised to preserve the same boundary within the tolerance band.

A separate `(1 + tool radius + tool length)*1e-8` mm numerical guard is recorded.
It is a practical floating-point guard, not an interval-arithmetic proof of all
rounding errors. Analytic bounds describe ideal arithmetic; tests cover random
poses, tangencies, caps and transforms. These algorithms are outside the Lean
model. Existing proofs and bridge tests do not prove this executable.

## Material, surfaces and error sources

- The state stores continuous closed interval surfaces. Subtraction is regularized:
  zero-length tangent cuts do not split material or change volume. Boundary-only
  membership can differ from closed-cutter voxel-center semantics.
- XY rays sample stock and cutting geometry at cell centers. A thin feature between
  rays can be missed. Neither 25 µm nor 6.25 µm spacing guarantees that maximum
  3D surface error. There is no additional Z quantization in stored endpoints.
- Reported material volume is `sum(interval lengths) * spacing²`, a transverse
  quadrature approximation. Initial analytic cylinder volume is also reported.
- OBJ export assigns each ray its square XY cell and emits the exposed boundary
  of that column solid. It preserves interval heights, omits shared interior
  faces and performs no smoothing. This is a separate reconstruction choice.
- Export checks signed mesh volume against interval volume. Optional oriented
  edge-coverage checks account for collinear subdivisions/T-junctions; they are
  not a claim that the unindexed quad mesh is a conforming manifold mesh.
- Mesh lighting and image sampling do not change interval metrics. The screenshots
  show the actual derived material, without a fabricated toolpath or animation.

## Allocation and resource boundaries

All allocators are explicit. A thread-safe wrapper protects the caller's allocator;
there are no allocations inside a ray traversal or per longitudinal voxel.
Column/result pools grow amortized between rays. Results remain unpublished until
all workers and deterministic merging succeed; errors join workers and free
partial results. There is no mutation of an existing authoritative stock on failure.

The fixed method reserves one scratch interval per prepared pose plus one. The
adaptive method reserves 4,096 material and witness intervals per worker and
returns `RayIntervalBudgetExceeded` rather than truncating. Temporal refinement
is limited to depth 24/five million nodes; fixed preparation to five million poses;
transverse dimensions to 65,536. These are checked implementation limits, not
claims that the largest permitted workload fits memory. Capacities and process
RSS are reported separately, including worker scratch and merge high-water costs.

At 25 µm, the new interval material uses about 20.6 MB, versus approximately
13.25 MB of descriptors/pool in the earlier production voxel run. Its much lower
process RSS largely reflects omitted history/provenance, not universally superior
material compression. Tri-directional storage is not added until its surface
benefit and consistency rules justify the extra work and memory.

## Reproduce validation and measurements

```sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
python3 scripts/test-raydexels.py --out out/ray-tests-new
python3 scripts/benchmark-raydexels.py --workers 8 --out out/ray-measurements-new
```

The benchmark alternates fixed/adaptive order, uses one warm-up plus three
repetitions at 250/100/50/25 µm, validates deterministic serialized endpoints,
and records source/binary/job identifiers. Raw unfavorable intermediate results
and the slower adaptive results are retained. Jens's reported time cannot be
turned into a speed ratio without his resolution, workload and measurement scope.
