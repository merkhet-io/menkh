# Follow-up: cached STL ray calculations

The unchanged 25 µm imported finishing job now takes **48.05 s median**, compared
with **52.23 s** for the pre-cache executable in an alternating before/after run.
This is an **8.0% reduction in whole-process time**. Combined stock and target
voxelization falls from 31.66 to 27.44 s (13.3% less time). Peak process RSS remains
119,767,040 bytes for both versions. The workload, motion tolerance, output settings
and one-worker execution are unchanged from the [frozen protocol](FINISHING-PROTOCOL.md).

| Phase | Before median (range), s | Cached median (range), s |
|---|---:|---:|
| Whole process | 52.228 (52.084–52.372) | 48.053 (47.825–48.280) |
| Stock + target voxelization | 31.659 (31.583–31.736) | 27.438 (27.287–27.589) |
| Cutting | 19.416 (19.368–19.464) | 19.511 (19.465–19.557) |
| Cache construction, combined | 0 | 0.00195 (0.00189–0.00202) |

There was one warm-up and two measured repetitions per binary, alternating order.
The slight cutting regression is retained; this change does not optimize cutting.
Two repetitions establish the observed range, not a population confidence interval.
Hardware and configuration are the same M5 Max / Zig 0.15.2 / ReleaseFast used in
[the original milestone](FINISHING-RESULTS.md). Before-binary SHA-256 matches that
milestone's recorded executable. The prior 51.99 s median remains valid historical
evidence; the table above uses a fresh paired baseline.

## Change and memory tradeoff

Mesh import now precomputes triangle edge vectors and, for each of the three fixed
parity directions, the cross product, determinant and parallel-test result. It
builds the cache after BVH triangle reordering and releases it with the mesh.
The inner query retains original divisions, boundary tolerances, parity comparison
and ambiguous-edge retries. There is no scanline classifier or changed inside/outside
policy in this optimization. The uncached classifier is retained and used by
`--reference` voxelization.

The cache costs **168 bytes per triangle**, or **8,580,096 bytes per fixture mesh**.
Stock and target meshes are imported sequentially. This temporary allocation does
not increase this workload's whole-process high-water mark, reached later, but it
is a real memory cost and may raise peak RSS for other meshes. The one-million
triangle input limit bounds cache size at 168 MB. Allocation failure remains an
error with unpublished import cleanup; no per-query allocation is introduced.
Reports expose cache construction time and allocated bytes explicitly. The
reference allocates the cache too, although its classifier does not use it.

## Validation

Across all six full runs, initial stock and target descriptor/pool files match
byte-for-byte, and final canonical occupancy matches:
`6971519449ef91e2fc0ca7dbbade173feeaa6393a2f2daa3f6914d869517eab7`.
The change therefore preserves the original run's two missing target centers,
excess material, motion tolerance and accuracy limitations. It does not improve
geometric accuracy or change the interpretation of the existing error evidence.

All **47 Debug and ReleaseFast tests pass**. The added test compares cached and
uncached queries at 18,000 random points, multiple scales and translations, plus
faces, edges, vertices and points on either side of the existing boundary tolerance.
Random points also use an independent cube-membership oracle. The ten rotated,
concave, cavity, thin and disconnected mesh fixtures pass their existing independent
oracles. The varied suite passes, and the complete 250 µm smoke workflow again
passes checkpoint and compacted-checkpoint resumption. Existing formal checks pass;
this cache and its executable relationship are not newly formally verified.

## Reproduce and retained evidence

Build the pre-cache revision `3a8aeff` in a separate checkout with the same compiler,
retain its executable, then build the current revision and run:

```sh
./zig build -Doptimize=ReleaseFast
python3 scripts/benchmark-import-cache.py --before /path/to/pre-cache/menkh
```

The script generates the same fixture, alternates the two executables and validates
occupancy plus imported buffers. [Raw records and identities](../benchmarks/import-cache/)
include all operations and warm-ups. Measured source hashes identify working-tree
changes precisely. Runtime excludes subsequent digest verification; both binaries
use identical output settings. Writes are cached, not durable-storage measurements.

Voxelization remains the largest phase. Robust reuse of ray intersections across
neighboring sample locations is still the next substantial opportunity; any change
in classification will need the same independent mesh and exact-occupancy checks.
