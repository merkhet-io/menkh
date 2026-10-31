# Experimental quantized Z-dexel cutting

Alternate material structures are now permitted. The first executable experiment
stores material as sorted Z intervals in sparse XY columns, rather than an array
of 8³ voxel-block descriptors. It is **not the production job backend**.

The interval endpoints are initially integer grid indices. This deliberately
preserves the existing center-occupancy semantics so storage and traversal can
be compared without simultaneously changing the accuracy contract. It is not
continuous-endpoint or tri-dexel reconstruction. A future continuous dexel or
hybrid implementation is allowed, but needs its own error/inspection contract.

## What works

- Explicit origin/domain/spacing; sparse, sorted XY columns of a +Z cylinder.
- Material subtraction through the existing validated shape/sweep predicates.
- Recursive interval inclusion/exclusion; disconnected spans and cavities.
- Exact output-size preflight, capacity reservation and double-buffered commit.
  Allocation failure preserves authoritative columns and intervals. Obsolete
  intervals are compacted into the other buffer each operation; two capacities
  are retained, not an append-only history. No allocation per cell or recursion.
- Full result comparison against saved voxel checkpoints, including every sample
  in every originally occupied column and total occupancy outside those columns.
- Explicit operation-prefix and virtual-world probes.

No imported stock, arbitrary job CLI, history, serialization, surface export or
viewer integration is provided by this experiment. The existing production
engine and saved grinding demo continue to provide those facilities. It would
be misleading to compare the experiment's process RSS with the full job's RSS
as if the same history/provenance/export services were enabled.

```sh
./zig build -Doptimize=ReleaseFast
zig-out/bin/menkh dexel-bench --voxel 0.1 --check-state out/screw/result/final.menkh --out out/dexel-screw
zig-out/bin/menkh dexel-bench --world-grid 16384 --operations 16 --out out/dexel-16k-prefix
```

Both use the frozen two-start screw path. Output directories must be fresh.
The `--check-state` checkpoint must have the same grid, origin, path prefix and
spacing. On Windows use `zig-out\bin\menkh.exe`. Other options are
`--tolerance` and `--steps-per-turn`, with the same limits as `grinding-demo`.

## Measured result and decision

Apple M5 Max, Zig 0.15.2 ReleaseFast, one worker; same 100 µm screw geometry,
1,024 operations, 0.01 mm motion budget. One experimental qualification run,
with development checks overlapping part of its execution—not a repeated
head-to-head benchmark:

| Quantity | Quantized interval experiment |
|---|---:|
| Cutting, including transactional dry/write passes | 224.237 s |
| Initialization | 0.323 ms |
| Initial occupied centers | 4,521,600 |
| Remaining occupied centers | 3,604,560 |
| Sparse XY columns | 11,304 |
| Final intervals | 63,600 |
| Column/interval capacities, including both scratch buffers | 1,494,064 B |
| Process RSS before loading the comparison grid | 4,489,216 B |
| Full center-occupancy comparison | Passed |

The production voxel kernel's repeated median cutting time was 14.718 s. Its
live descriptor/pool capacities were 356,616 B, with cut scratch separately
recorded in the raw report. The interval implementation is clearly worse on
this compact screw, despite omitting history. Its lower process RSS is **not**
a like-for-like memory improvement: the production job also retains/generates
exposure provenance and writes replay/export data.

This does not establish that dexels are intrinsically slow. The prototype uses
generic signed-distance interval subdivision and repeats traversal for preflight;
it has no analytic wheel/ray interval solver, prepared tool-frame batching,
tri-directional representation or shared-column hierarchy. Its counters count
interval decisions and leaf tests, not all internal point–pose evaluations.

The 16k³ probe uses the same small physical blank in a much larger virtual world,
not a 16k-resolution screw. Unlike the dense descriptor backend it can initialize
that domain and execute a cut prefix without allocating the empty world. See
`dexel-16k-prefix.json` in the evidence directory for actual measurements.
Full-resolution 16k screw grinding has **not** been demonstrated.

**Decision:** retain the measured voxel optimization as the production default.
Keep this bounded, tested experiment as an exact-comparison oracle for the next
structure trial. The next useful experiment is prepared analytic or bounded
ray/tool interval intersection, or a hierarchy sharing uniform regions/columns,
measured on the same screw. More tool types and display smoothing will not solve
this bottleneck. These algorithms are outside the existing Lean model.
