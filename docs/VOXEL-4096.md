# Exactly 4096 × 4096 × 4096 voxels

[**Watch the new animation**](drill-4096.mp4) · [Preview image](drill-4096.png)

The high-resolution version is implemented and has actually been run. **All three grid dimensions are 4096**, not just the drill length. This provides 68,719,476,736 addressable cells in a 60 × 60 × 60 mm simulation volume, with **14.6484375 µm cubic voxels**. The Ø 12 × 60 mm cylinder is centered at XY = (30,30), leaving the surrounding region empty. Initially, **2,159,116,288 voxels are occupied**; after cutting, **1,333,399,870** remain. Addressable cells are not reported as occupied or individually processed voxels.

## Launch and controls

```sh
./scripts/drill-4096.sh
```

Or open existing data directly:

```sh
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting
```

- Drag to orbit; scroll to zoom.
- **Double-click a surface** to focus the camera on the actual hit voxel. You can then zoom down to individual voxels.
- Shift + drag to pan the focus point.
- Scrub the timeline forward and backward through the actual cutting history.
- Pause/play, restart, and reset the camera.
- Toggle normal averaging to change lighting only. Contours, hit positions, occupancy, and volume remain unchanged. The launch script enables this option; the viewer explicitly labels it and allows it to be disabled.
- Optional dark background.

The animation remains a precomputed geometric demo. Playback duration does not represent machine feed time. The spherical cutter, helical polylines, and simplified tip faceting follow the [previous demo](DRILL-DEMO.md); finer voxel spacing does not make the geometry production-approved.

## Relationship to the requested videos

**Only the three newest videos** on [jstimpfle's profile](https://handmade.network/m/jstimpfle) were used as visual references, each inspected at multiple timestamps:

1. [October 9: cutting history](https://assets.media.handmade.network/52b4a944-b54a-484b-af96-2bfb08483204/JCut_Recording_2026-10-09_120752.mp4)
2. [October 9: detail levels and close-up](https://assets.media.handmade.network/c57e31b2-ac6d-4c26-aec7-73e409c82000/JCut_Recording_2026-10-09_114621.mp4)
3. [September 11: surface and zoom](https://assets.media.handmade.network/cc886f5f-d0f6-4ca2-a1d1-c4b31757c928/Screen_Recording_2026-09-11_191224.mp4)

The visual direction—blue material against an orange background—along with close inspection through orbit and zoom and navigation through cutting history, informed this viewer. Geometry and implementation belong to this project. This is neither an exact reproduction nor a claim to match the performance reported in those videos.

## Implementation

**Material removal: Zig, CPU, one worker.** The dense array of compact 8³ block descriptors and contiguous bitfield pool remain in use. There is no octree or GPU cutting. The constant-Z end-mill API is unchanged.

`src/fine.zig` adds block classification tailored to the drill demo:

- Cylinder initialization visits only blocks that can contain material; surrounding descriptors remain empty.
- Cylinder inclusion and exclusion tests use minimum and maximum radial distances of the voxel-center box.
- For 3D capsules, all eight corner centers with safety clearance prove complete containment; a capsule expanded by the block radius provides conservative exclusion.
- Tip planes use the block's extreme dot products.
- Individual occupied voxel centers are evaluated only for partial overlap. All CPU geometry predicates use `f64`.
- Pool and change-buffer capacities are prepared before the write pass. The inner voxel loop performs no allocations.

**Rendering: direct Metal voxel rendering** in `viewer/VoxelView.swift` and `viewer/Voxel.metal`. The renderer reads block descriptors and bitfields. Rays skip empty blocks and traverse individual voxels inside mixed blocks. It generates no huge mesh and displays no coarser substitute grid. Four rays per output pixel provide antialiasing. Optional lighting normals are averaged over a 5³ voxel neighborhood; surface positions still come from the first occupied voxel hit. Shader and camera calculations use `f32`, while simulation uses `f64`. This does not establish a certified geometric error bound.

The new renderer is independent of SceneKit and uses the existing macOS Metal/MetalKit frameworks. The original OBJ/MQ viewer remains available for older demos. No global dependencies were installed. CPU updates wait for the preceding GPU command buffer, preventing changes to data while the GPU is reading them.

**History instead of complete surface copies:** `initial.blocks` stores the actual complete descriptor array; `initial.pool` stores the initial bitfields. Each `.delta` file stores each changed block's ID, previous and next descriptors, and, when needed, previous and next 64-byte bitfields. This makes the history directly reversible. `voxel-animation.json` records dimensions, occupied voxels, steps, file sizes, memory usage, and timings. These specific state files can be reloaded; there is still no general CAD or G-code import format.

## Measured results

M5 Max, 128 GB RAM, macOS 27.0.1; Zig 0.15.2, ReleaseFast, native CPU target, **one worker**. One complete warm-up followed by three repetitions in fresh CLI processes, each starting with identical stock. Files were written through the warm macOS filesystem without `fsync`. There was no CPU affinity or thermal isolation. The sum of phase medians need not equal the median total runtime.

| Phase | Median | Min–max |
|---|---:|---:|
| Initialize cylindrical stock | 180.05 ms | 176.04–182.32 ms |
| Initial occupancy statistics | 86.71 ms | 73.76–90.13 ms |
| Export initial state | 80.49 ms | 70.59–80.95 ms |
| All 224 cutting operations, including preparation | 2,705.94 ms | 2,677.67–2,942.38 ms |
| Export all change files | 49.84 ms | 48.78–51.65 ms |
| Complete generation including final validation | **3.160 s** | **3.155–3.405 s** |

Measured peak RSS across the three CLI processes: **647,512,064–647,528,448 bytes**. Actual block-descriptor allocation: **536,870,912 bytes (512 MiB)**. Final bitfield-pool capacity: **51,714,560 bytes**. Stored changes across all steps total **126,358,276 bytes**. A fully materialized 4096³ bitmap was not allocated; these figures are not estimates of its memory requirements.

A static Metal view at **1280 × 900 output pixels**, using the final 4096³ state, four samples per pixel, and averaged lighting normals, was measured ten times after three warm-ups: GPU command duration was **1.872 ms median**, **1.719–1.960 ms** min–max. This is GPU time for the static initial camera, **not a guaranteed interactive frame rate**. Delta upload, CPU control, video encoding, and display VSync are excluded. Strong zoom and full image coverage can change the workload.

Raw data: [CPU summary](../benchmarks/4096/summary.json), [complete simulation](../benchmarks/4096/simulation.json), [GPU measurement](../benchmarks/4096/render.json), [replay validation](../benchmarks/4096/replay.json), and the three individual runs in the same directory.

## Validation

- **17/17 test groups** passed in Debug and ReleaseFast.
- New block classification was checked against exhaustive voxel-center oracles; existing tests for the original cuts continue to pass.
- New allocation-failure tests confirm unchanged occupancy when reservation fails.
- Small test grids produce identical block bits after forward/backward/forward replay.
- **On the actual 4096³ dataset:** replay to the end, back to the beginning, and to the end again. Initial descriptors and all original pool bits are byte-for-byte identical after rewinding; both final passes yield 1,333,399,870 occupied voxels.
- The MP4 was actually rendered and fully decoded with the existing FFmpeg installation; a close-up frame from the finished video was visually inspected.

## Reproduction

```sh
./zig build drill -Doptimize=ReleaseFast -- --grid 4096 --out out/drill-4096
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting

./scripts/benchmark-4096.sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all

zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --verify-history out/drill-4096/replay.json
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --frame 224 --smooth-lighting --render-bench out/drill-4096/render.json
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --frame 224 --smooth-lighting --snapshot out/drill-4096/preview.png
# The video destination must not already exist:
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting --movie out/drill-4096/new-video.mp4
```

`--grid` and `--voxel` are mutually exclusive. Grid size must be a multiple of eight between 32 and 4096; lower values are explicit test options. The demonstrated run uses 4096 on every axis. The new video export contains **1280 × 900 image pixels**, runs at 12 fps, and lasts 25.75 s: image resolution and spatial grid resolution are separate quantities.
