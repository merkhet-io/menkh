# Large-world qualification — issue #11 remains open

The requested 65,536³ virtual space and 2³² exposed voxel faces within 16 GB are
**not supported by the current mutable grid**. Raising a dimension check would
not solve the storage problem. This report records actual failures and the
existing alternative's benefits and regressions; it does not claim a new engine.

Reproduce with the repository-local compiler:

```sh
./zig build -Doptimize=ReleaseFast
python3 scripts/qualify-large-world.py --tiles
```

The script writes exact jobs, binary/source identities, actual failure messages,
measured elapsed times and the raw tiled-snapshot results. Capacity formulas are
explicitly separate from measurements. The probes time out after 30 seconds but
do not enforce a 16 GB memory budget. A successful initialization alone would not
qualify cutting, replay or billions of surface faces.

## Executed capacity probes

Both probes use a **1 × 1 × 1 mm stock** in the larger world, at 0.01 mm spacing.
That isolates empty-world overhead from the actual material volume.

| World grid | World extent | Actual result | Calculated descriptor capacity |
|---|---|---|---:|
| 20,000³ | 200 mm per axis | `GridTooLargeOrEmpty`, before grid allocation | 62,500,000,000 bytes |
| 65,536³ | 655.36 mm per axis | `GridTooLargeOrEmpty`, before grid allocation | 2,199,023,255,552 bytes (2 TiB) |

These byte values are calculations, **not allocations or measured RSS**. The
existing block index/sentinel space rejects these descriptor counts. The 65,536³
binary occupancy array alone would take 32 TiB if represented densely. Also, one
uncompressed u32 metadata label for each of 2³² faces consumes 16 GiB before any
occupancy, indices, history, scratch or renderer memory. Compression/sharing is
therefore required if such labels are included in the same budget; this is not
an impossibility claim for a compressed surface representation.

## Executed immutable-snapshot comparison

Apple M5 Max, Zig 0.15.2, ReleaseFast, one worker. One warm-up and four measured
repetitions per scene. Each representation receives the same one million seeded
queries and must return the same hit count. Raw records retain min/max and peak
process RSS; the table uses medians and decimal MB.

| Case | Dense allocation | Tiled allocation | Dense query time | Tiled query time | Snapshot construction |
|---|---:|---:|---:|---:|---:|
| 4096³ sparse cylinder | 550.14 MB | 33.42 MB | 11.81 ms | 6.75 ms | 194.85 ms |
| 4096³ full cube | 536.87 MB | 537.92 MB | 11.02 ms | 18.61 ms | 910.83 ms |

Allocation columns include descriptor/pool capacities, not just used bits. Peak
process RSS was 584.22 MB for the cylinder phase and 1,076.79 MB for the full-cube
phase. Both grids coexist during conversion; RSS is a process high-water mark,
not either representation's standalone footprint. Query timings include the
seeded coordinate generation and are not cutting throughput.

The tiled representation has a dense coarse directory and allocates descriptor
tiles for nonempty regions. It saves empty-space storage but still expands full
solid interiors into tiles. It is an **immutable inspection snapshot**: it does
not establish mutation throughput, bounded history, pool reuse, or replay
correctness. It cannot be substituted for the mutable cutting grid on this
benchmark alone. No 65,536³ or 2³²-face execution is claimed.

## Engineering decision and next acceptance gate

Keep issue #11 open. The next storage experiment must represent uniform full and
empty regions above the 8³ block level and allocate detail near boundaries, while
supporting transactional mutation and reversible history. The measured full-cube
regression rules out treating the existing snapshot layout as a complete answer.

Qualification must include the rejected sparse-world cases, filled interiors,
thin/disconnected geometry and enclosed cavities; small-grid occupancy equality;
failed-allocation behavior; cuts across coarse boundaries; checkpoint/resume and
forward/backward replay; then long-job memory with history retained. Only after
those checks should an actual 2³²-face stress case be used to assess the 16 GB
requirement. Surface count, runtime, peak RSS, live capacities and history must
all be measured. This milestone supplies reproducible failure cases and evidence,
not that future implementation.

Raw records: [`benchmarks/large-world-qualification`](../benchmarks/large-world-qualification).
