# Pocket video: volume and surface counts

The 25 µm video uses a **1200 × 960 × 640** domain (30 × 24 × 16 mm):
737,280,000 addressable voxel positions, including air. The initial 24 × 18 × 8 mm
cuboid occupies 221,184,000 of those positions.

The saved final state contains:

- 170,711,351 occupied **volume** voxels.
- 50,472,649 removed volume voxels (788.635140625 mm³ raster volume).
- **2,819,284 surface voxels**.
- **2,883,920 exposed unit voxel faces**.

A surface voxel is an occupied cell with at least one empty neighbor across one
of its six faces. Count it once, even at edges/corners. Outside the finite grid is
empty; enclosed cavity boundaries count. Faces, mesh quads, volume voxels and
surface voxels are distinct quantities. No mesh generation or timing of surface
voxel *creation* is implied by this inspection of a saved state.

```sh
./zig build -Doptimize=ReleaseFast
zig-out/bin/menkh inspect-state out/demo-performance-25um/final.menkh
# Or reproduce the exact job first:
zig-out/bin/menkh job examples/pocket-25um.json --out out/pocket-25um
zig-out/bin/menkh inspect-state out/pocket-25um/final.menkh
```

Raw inspection reports are in `benchmarks/inspection`. An independent pointwise
six-neighbor test validates the block-bit implementation, including partial edge
blocks and random occupancy. The 100 µm version has 174,441 surface voxels and
180,180 exposed faces, for 2,667,022 remaining volume voxels.

## Storage and comparison with a surface-only engine

Occupancy means material present/absent at the voxel center. The engine stores a
dense array of 32-bit descriptors for 8³ blocks. Empty and full blocks use no fine
bitfield; mixed blocks refer to eight u64 words in a shared pool. There is no
mutable octree or surface-only representation. Full blocks can be rejected or
removed collectively; selected partial blocks use column/bit masks.

Thus removed voxel count divided by time is not the number of explicit geometric
tests/s. Nor is an eight-worker cache-resident point-predicate rate an end-to-end
comparison with an engine that maintains only boundary voxels.

If Jens means `(2^14)^3`, his addressable domain is 16384³ = 4,398,046,511,104
positions. This domain is not supported by the current dense block directory:
it needs 8,589,934,592 descriptors (32 GiB for descriptors alone), beyond the
current 32-bit block-ID limit. The validated 4096³ drill is a different, smaller
case. Five billion surface voxels would also be a much larger surface workload
than this video's 2.82 million; this is not a measured speed ratio.
