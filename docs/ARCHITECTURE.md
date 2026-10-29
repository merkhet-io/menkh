# Architecture and contracts

## Data flow

`main.zig` → `core.Grid.init` → `Grid.cut` → statistics → `surface.generate` → PPM/OBJ/JSON. The mesh viewer reads exported geometry only. Rendering never changes the material state.

- `src/core.zig`: allocator-based block grid, geometry predicates, reference and optimized cutting.
- `src/surface.zig`: visible voxel boundaries, block-local greedy merging, image and mesh export.
- `src/main.zig`: CLI, fixed example scenario, validation, and benchmark timing.
- `src/tests.zig`: 17 test groups, including randomized sequences and allocation failures.
- `viewer/main.swift`: optional standalone macOS viewer.

## Material state and memory

A flat array of `u32` descriptors addresses blocks in X-fastest order: `(bz * nby + by) * nbx + bx`. `0xffffffff` means empty, `0xfffffffe` means full; other values index a contiguous `ArrayList([8]u64)` pool. A mixed block uses 64 bytes. Word `z` contains an XY layer; bit `y * 8 + x` represents its local voxel. There are no per-voxel pointers or allocations inside voxel loops.

“Full” means that **all valid voxel centers** in the block are occupied. Nonexistent boundary voxels are neither counted nor exported. Boundary masks are generated on demand without consuming a pool slot. The initial cuboid needs only the descriptor array. Statistics use `popCount` for mixed blocks and the actual valid extent for full blocks.

Before each operation, a read-only pass counts exactly how many full blocks will become mixed. Pool capacity is then reserved before a second pass changes the material state. If reservation fails, occupancy remains completely unchanged. The reference uses the same preparation, ensuring equivalent allocation conditions. After reservation, the entire cutting write pass performs no allocations.

Once materialized, a block can never become full again through removal alone. Slots belonging to blocks that have become empty remain in the pool until `deinit`; they are not reused. Pool usage therefore grows monotonically and is bounded by the number of blocks that have ever been mixed. `pool_used_bytes` includes these retained slots; `mixed_blocks` counts only currently mixed blocks. Capacity is requested exactly, with no silent truncation when space is insufficient.

All allocators are passed explicitly. Dimension products and capacity sums are checked; allocators also check their byte sizes. At most 2³¹−1 voxels per axis and fewer than `0xfffffffe` blocks or pool slots are accepted. Size errors produce `GridTooLargeOrEmpty`, `PoolTooLarge`, or `Overflow`; insufficient memory produces `OutOfMemory`. This is a bounded cuboid simulator, not an unbounded world grid.

## Coordinates and numerical rules

- The origin is the lower-left bottom corner of the stock, (0,0,0), with Z pointing upward. All units are mm.
- The center of global voxel index `(i,j,k)` is `((i+0.5)h,(j+0.5)h,(k+0.5)h)`.
- An initial voxel exists exactly when its center lies inside the half-open ideal cuboid `[0,Lx) × [0,Ly) × [0,Lz)`. Dimensions obtained by division are corrected against the actual center predicate.
- Out-of-bounds `occupied` index queries return `false`. Spatial `query` calls use `floor(p/h)` and the bounds of the **represented grid**, `[0,nx*h) × …`, rather than reapplying the ideal stock dimensions. Queries, meshes, and volume therefore agree even at stock boundaries that are not integer multiples of the spacing. Negative, non-finite, or excessively large coordinates return `false`.
- Voxel size, stock dimensions, and tool dimensions must be positive and finite. A grid containing no voxel centers is rejected. Stock dimensions, tool dimensions, and absolute motion coordinates are limited to 10⁶ mm. Applications should still use small, workpiece-local coordinates.
- Tool position is the center of its lower flat face. Radius and cutting length are positive. Both motion endpoints must have **exactly the same Z**; Z is never silently corrected. Stationary motion is valid.
- Endpoints are ordered lexicographically by XY, so reversing a segment performs identical floating-point calculations.
- `t = clamp(dot(p-a,b-a)/|b-a|²,0,1)`; stationary motion uses `t=0`. A voxel is removed when `distance² <= (radius+1e-10)²` and `a.z-1e-10 <= p.z <= a.z+length+1e-10`. The tolerance is absolute in mm, not a percentage or grid smoothing. Fast math is not enabled.

## Reference and optimization

The scalar reference evaluates the complete 3D predicate for every valid voxel in conservatively bounded candidate blocks. It uses the same occupancy representation and transactional preparation. In addition, randomized tests check **every** grid voxel, without bounding-box restrictions, against a separate Boolean occupancy oracle. This also detects candidate-bound errors shared by both implementations.

The optimized implementation:

1. Conservatively bounds the capsule AABB to block ranges; valid voxels within those ranges are bounded by each block's extent. Extra voxel padding protects against rounding errors.
2. Skips empty blocks. Material outside the candidate ranges is neither read nor modified.
3. Tests the four extreme **voxel centers** of the XY rectangle. If all lie inside the convex capsule with an additional 1e-8 mm clearance, all XY centers are contained. A single block-center test is never used as proof of containment. Borderline cases use individual point tests.
4. Otherwise evaluates at most 64 XY predicates per block and reuses the resulting mask for every axially affected Z layer. Invalid boundary voxels remain masked out.
5. Removes material word by word with `before & ~cutMask`. A completely removed block becomes empty directly, without materializing a bitfield. Unchanged blocks are not rewritten.

Cutting time includes preflight checks and pool reservation. Optimization changes only the computation, not occupancy. Explicit `@Vector` operations and threading are not implemented. In the measured cuboid baseline, surface generation and serialization cost considerably more than cutting, so additional CPU complexity in the cutting path was not needed for this first version.

## Surfaces and rendering

Full blocks need to check only their six outer faces. A full neighbor completely hides the corresponding face. Mixed blocks check internal and external voxel boundaries against actual neighboring occupancy. Within each plane, equally oriented visible faces are merged into rectangles using 8×8 masks. Merging is block-local rather than global; coplanar rectangle edges can contain T-junctions.

The exported mesh is exactly the boundary of the represented union of voxels. Vertex positions are not smoothed, the material state is not replaced by a height field, and hidden voxel cubes are not emitted. General cut states also include enclosed cavity boundaries; the PPM can show only the highest occupied cell in each column. The mesh viewer generates explicit flat normals and two triangles per quad.

Each mesh export regenerates the complete surface. There is no incremental mesh cache or live simulation stream. The single-operation demo generates it once. The mesh GUI uses immutable geometry, so rotating and zooming require neither resimulation nor surface regeneration.

## Remaining limitations

The classic end-mill API does not support adding material, tilted tool axes, Z motion, rounded or spherical cutters, arcs, or G-code interpretation. The separate drill operations are described below and in the demo documentation. There is no general state-import command for the classic CLI or packaged macOS app distribution. The CLI is tailored to the example scenario. The legacy mesh viewer uses SceneKit, which Apple maintains without further feature development; the newer voxel viewer uses Metal directly.

## Extension: exact 4096³ grid

The additional `drill --grid 4096` path (`src/fine.zig`) retains the same block format but exports voxel state and reversible block changes instead of per-step meshes. `viewer/VoxelView.swift` and `viewer/Voxel.metal` render these data directly through Metal, without SceneKit. CPU material removal and GPU rendering remain separate. For conservative block classification, file formats, visual references, tests, and completed 4096³ runs, see [VOXEL-4096.md](VOXEL-4096.md).
