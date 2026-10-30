# Experimental mutable large-world storage

Issue #11 requests a 65,536³ virtual world and 2³² exposed faces within 16 GB.
The regular job engine still does **not** meet that requirement. This experiment
adds actual subtraction and retained history to a separate hierarchical store;
it does not replace `core.Grid` or silently change job formats.

`src/sparse.zig` uses a persistent octree with implicit full/empty nodes and
8³ mixed leaves containing the existing eight u64 occupancy words. Uniform
interiors do not allocate descendants. A subtraction classifies regions
conservatively, descends partial regions and evaluates leaf voxel centers.
Before mutation, a dry pass counts appended nodes/leaves; capacities are reserved
before the write pass. A completed operation publishes one new root. Allocation
failure leaves the published material and all earlier roots unchanged (capacity
may have grown). No per-voxel allocation occurs.

Earlier roots reference immutable nodes/leaves. No slots are reused, so backward
and forward selection is exact. This also means retained memory grows across a
long job: it is **not** a bounded-history solution. There is no checkpoint format,
compaction, general-job integration, mesh import, viewer streaming or surface
enumeration for this backend yet. Only power-of-two cubic, initially full stocks
from 8³ through 65,536³ are supported. This is an experimental Zig module and
benchmark, not a public SDK contract.

## Reproduce

```sh
./zig build test
./zig build test -Doptimize=ReleaseFast
./zig build -Doptimize=ReleaseFast
./zig-out/bin/menkh sparse-bench out/sparse-mutation
```

The benchmark performs 24 overlapping spherical cavity cuts near both ends of a
full cube at 10 µm spacing, with one warm-up and four measured repetitions. It
checks retained-root counts and compares final counts with the dense engine at
4096³. Separate small-grid randomized tests compare **every voxel** with scalar
dense subtraction and retain all prior roots. All allocation sites are exercised
with failure injection; idempotent cuts must not grow storage.

First local run, Zig 0.15.2 ReleaseFast, Apple M5 Max, one cutting worker:

| Case | Median cut time (range) | Retained node/leaf capacity | Root history |
|---|---:|---:|---:|
| Sparse 4096³ | 3.133 ms (3.116–3.291) | 66,784 bytes | 100 bytes |
| Dense 4096³ | 2.288 ms median | 536,879,296 bytes descriptors/pool | Not included in this capacity column |
| Sparse 65,536³ | 3.157 ms (3.128–3.176) | 66,784 bytes | 100 bytes |

The sparse case is slower here; its benefit is implicit uniform space. The dense
initialization median is 37.965 ms. The process high-water mark is 539,049,984
bytes, including the dense comparison performed earlier in the same process;
it must not be presented as sparse-only peak RSS. Raw records are in
`out/sparse-mutation/sparse.json` and the checked-in issue evidence.

Both scenes remove 29,240 voxels. The 65,536³ cube begins with 2⁴⁸ represented
occupied cells, without allocating them individually. These are a handful of
small cavities, **not billions of boundary faces**. The 2³²-face/16 GB target
remains unqualified. The next gate is checkpoint/compaction and bounded retained
history, followed by integration and genuinely surface-heavy qualification.

This module is outside the current Lean model. Its root/arena relationships are
covered by executable tests, not a proved Zig refinement.
