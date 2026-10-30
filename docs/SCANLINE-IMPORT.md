# Shared scanlines: measured STL import improvement

The unchanged imported ball-finishing job at 25 µm now completes in **25.58 s
median**, down from **47.47 s** in a fresh paired comparison. Combined stock and
target voxelization falls from **27.18 s to 5.35 s** (5.08× faster). This is a
46.1% reduction in whole-process time, with cutting unchanged at about 19.29 s.

| Measurement | Before median (range) | Scanlines median (range) |
|---|---:|---:|
| Process wall time, s | 47.473 (47.424–47.522) | 25.579 (25.571–25.587) |
| Stock + target voxelization, s | 27.179 (27.152–27.206) | 5.347 (5.338–5.356) |
| Cutting, s | 19.324 (19.294–19.354) | 19.293 (19.290–19.296) |
| Peak process RSS, bytes | 119,767,040 | 119,816,192 |

These are one warm-up plus two measured repetitions per binary, in alternating
order, on the same M5 Max, Zig 0.15.2, ReleaseFast, one CPU worker. Peak RSS changes
by 49,152 bytes; temporary scratch storage is reported separately below. The
before executable hash matches the [previous cache benchmark](IMPORT-CACHE-RESULTS.md).
The [frozen workload](FINISHING-PROTOCOL.md), geometry, 5,199 segments, 5 µm motion
tolerance and output settings are unchanged. No speedup is inferred from predicate
counts. File writes are cached writes, not durable-storage measurements.

## Algorithm and safeguards

Vertical intersections are shared across a block column rather than recomputed
for each query height. Projected BVH traversal collects a complete line's triangle
crossings. Sorted even/odd intervals handle enclosed cavities and disconnected
pieces. The existing surface-exclusion test still determines whether a connected
region is uniform; a boundary block is never filled from its midpoint alone.

The cache has 225 possible XY midpoint keys per 8 × 8 column. It also checks actual
floating-point XY values before reuse. Ambiguous edge/vertex hits, nearly parallel
or poorly conditioned projections, odd event counts, nearby event pairs, and
near-surface points fall back to the established three-direction classifier.
Ambiguous events are not merged or assigned a new half-open convention.

Event capacity is fixed before traversal and capped at **65,536 doubles / 512 KiB**.
If it is exhausted, the entire line uses fallback; geometry is never truncated.
The cache does not allocate per query. An import-only temporary buffer restores
pool entries to canonical descriptor order before publishing the grid or creating
history. Existing history slot references are therefore unaffected.

On each representative stock/target import:

- 768,613 scanline constructions are reused across about 2.1 million point queries.
- Only 11 point queries need three-direction fallback.
- Reported scanline scratch is **1,223,752 bytes per import**, including line records,
  event storage and the temporary pool-order buffer.
- The previous **8,580,096-byte triangle-ray cache** remains for fallback queries.

Scratch buffers are temporary and stock/target imports run sequentially. They are
real allocations even though the process high-water mark changes very little.
Allocation failure destroys the unpublished imported grid. Reference voxelization
still visits every center with uncached three-direction parity.

The numerical guards scale with coordinates and projection conditioning. They are
engineering safeguards backed by differential tests, **not certified interval bounds
for every floating-point input**. The new classifier is outside the Lean model.

## Correctness and regression evidence

All six full benchmark runs match initial stock and target descriptor/pool files
byte-for-byte. Final canonical occupancy remains:

`6971519449ef91e2fc0ca7dbbade173feeaa6393a2f2daa3f6914d869517eab7`

The 250, 100 and 50 µm finishing runs also reproduce the previously saved final
state files byte-for-byte. Those are validation runs rather than repeated timing
measurements.

The full 25 µm checkpoint/resume and compacted-checkpoint/resume variants match the
uninterrupted result. All 5,199 history delta files and the history manifest match
the pre-scanline run byte-for-byte. Pool compaction remains a new timeline boundary.
The native viewer's complete forward/backward/forward replay passes byte-exact
checks in a separate 1.075 s validation run.

All **49 tests pass in Debug and ReleaseFast**, including capacity exhaustion,
zero-crossing lines, face/edge/vertex centers, large translations, partial blocks,
canonical pool ordering and allocation-failure cleanup. Existing Lean proofs,
audits, bridge checks and deliberate-breakage guards pass without scope expansion.
The existing varied suite and ten imported-mesh oracle fixtures pass.

An additional suite accepts **13 transformed meshes**, comparing every voxel with
the scalar path and checking **285,360 centers** against independent cell-union
membership using inverse transforms. It includes full 3D rotations, nearly vertical
faces, millimeter and micrometer-scale parts, distant origins, thin features,
vertically stacked disconnected pieces and cavities. Sixteen points within 1e−5
local cell units of ideal cell planes are excluded from the analytic-cell comparison
because binary-STL float32 rounding changes that ideal surface. They remain included
in the complete optimized/scalar occupancy comparison.

### Existing importer restriction exposed by the expanded tests

Three generated, fully rotated cell meshes (`cavity-2`, `concave-2`, `thin-2`) are
rejected as `SelfIntersectingSTL` by both the retained old executable and the new
one, before voxelization. Removing the large translation does not change the
rejection. These are **recorded restrictions**, not successful classification tests.
Their root cause has not been resolved; the tests do not establish that the reported
self-intersections are genuine. Validation is not weakened and no geometry repair
is attempted. CI explicitly permits only these recorded rejection cases and fails
on unexpected new ones.

The independent accuracy results from the original finishing milestone remain
applicable to this exactly unchanged material result. The primary run still misses
two target centers; the earlier tighter-tolerance diagnostic is retained without rerunning it for
this import-only change. The distinction between
scallops, tessellation, motion and voxel errors is unchanged. Faster import makes
no new accuracy claim and does not turn 25 µm spacing into a maximum-error guarantee.

## Reproduce

```sh
./zig build -Doptimize=ReleaseFast
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
python3 scripts/test-finishing-import.py
python3 scripts/test-scanline-import.py
./scripts/verify-formal.sh
python3 scripts/finishing-workflow.py
```

For the paired benchmark, build merged revision `b584fe5` in a separate checkout
with the same compiler and retain its executable:

```sh
python3 scripts/benchmark-import-cache.py --before /path/to/before/menkh --out out/scanline/paired
python3 benchmarks/scanline-import/validate-resume.py
```

The benchmark script retains its historical filename but compares any supplied
prior executable. It checks hashes of initial stock/target buffers and final
occupancy on every repetition. [Raw evidence](../benchmarks/scanline-import/)
includes source/binary identities, all per-operation reports, test logs, resume and
replay records, and the parser-restriction diagnostics. Generated fixtures and large
material/history files are reproduced rather than checked in. CI includes the new
mesh tests; local results do not imply that this branch has run remotely.

**Cutting now dominates (~75% of runtime).** The next performance step should reduce
complete ball-end sweep distance evaluations while keeping continuous coverage and
its declared tolerance. Separately, investigate the three recorded STL-validation
rejections before broadening claims about imported geometry.
