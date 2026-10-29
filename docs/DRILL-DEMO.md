# From a cylinder to a twist drill

This demo shows progressive **actual voxel removal**. The Zig process maintains a single material state and applies cuts sequentially, exporting its unmodified voxel surface at every animation step. The separate player loads these states on demand; pausing and rewinding do not repeat material removal.

## Watching the demo

- [Rendered MP4 animation](drill-demo.mp4): 273 video frames at 12 fps, 22.75 s, 960 × 960, H.264. A 1 s opening view, 225 material states, and a 3 s closing view.
- Interactive: `./scripts/drill-demo.sh` generates the data and launches the viewer. Controls include pause/play, restart, timeline, and camera reset; dragging rotates and scrolling zooms.
- Open an existing animation directly: `zig-out/bin/menkh-viewer out/drill/animation.json`.

## Geometry

The cylindrical blank is Ø 12 × 60 mm, aligned with Z, with XY center (6,6) and 0.25 mm voxel spacing. Initialization removes every voxel center outside radius 6 from the bounded block grid. The rendered surface remains visibly voxelized.

Two paths, offset by 180°, follow helices with radius 5.4 mm and pitch 32 mm per revolution from Z = 16 to Z = 62. Each helix consists of 96 straight **3D** segments. An idealized spherical cutting head with radius 3.3 mm removes the entire swept 3D capsule along each segment, leaving no gaps between discrete tool positions. The helix itself is a polyline approximation; its chord deviation at these parameters is approximately 0.006 mm, in addition to voxel approximation.

Next, 32 sequential inclined half-space cuts form the faceted tip. At angle α, a pass removes centers satisfying

```text
(x−6) cos(α) + (y−6) sin(α) > 60−z + 1e−10
```

This produces a simplified tip with an approximately 90° included angle. Finished rake and clearance angles, chisel-edge correction, and a functionally validated drill geometry are **not** modeled. The tip operation is an idealized planar shaping cut; the orange plate indicates its position and orientation, rather than a validated finite tool or holder. Holder collisions are also absent from the spherical-tool paths.

The sphere and plate are rendered transparently without depth occlusion so that the current tool position remains visible during cuts on the far side. These annotations do not change the material.

The original `Grid.cut` API for vertical end mills at constant Z remains unchanged and continues to reject Z motion. The distinct demo operations live separately in `src/drill.zig`; 3D motion is never silently reduced to the original XY capsule.

## Data and execution

`animation.json` describes voxel spacing, tool radius, playback rate, and each step's tool position, occupied voxel count, phase, and filename. The `frame-NNNN.mq` files contain merged visible quads only: 12 bytes per quad, comprising five little-endian u16 values (x, y, z, width, height), one axis byte, and one sign byte. These meshes are derived rendering data; the block voxel grid remains the authoritative simulation state. The viewer retains a small cache of neighboring frames rather than all meshes in GPU memory.

Before every operation, pool capacity is prepared using a conservative upper bound. Allocation failures leave occupancy unchanged; voxel tests perform no allocations. Capsule AABBs bound the blocks to process. Surfaces are fully regenerated for each animation state. The demo is precomputed, with no live coupling between the render thread and simulation core.

For this deliberately bounded demo, the `--voxel` CLI option accepts 0.1 to 0.5 mm. The first video uses 0.25 mm; it is not a 25 µm demo. The four original cuboid benchmarks, including their 25 µm configuration, remain available.

## Reproduction

```sh
./zig build drill -Doptimize=ReleaseFast -- --voxel 0.25 --out out/drill
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/drill/animation.json

# Render a single animation state:
zig-out/bin/menkh-viewer out/drill/animation.json --frame 224 --snapshot out/drill/final.png

# Export a video; the destination must not already exist:
zig-out/bin/menkh-viewer out/drill/animation.json --movie out/drill/new-demo.mp4

./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
```

MP4 export uses the existing Apple AVFoundation and SceneKit frameworks. No new global dependencies were installed. The existing FFmpeg installation was used only to independently verify the completed video.

## Completed validation

- All 225 material states were generated. The first measured generation, including all mesh files and the final OBJ, took 1.95 s on the M5 Max in ReleaseFast with one worker. This is a single measurement, not a benchmark median.
- Final occupancy: 267,344 voxels; removed volume: 2,587.75 mm³. Occupancy never increases between states.
- At this stage, 14/14 test groups passed in Debug and ReleaseFast, including the existing core checks. Added coverage included 3D capsules against exhaustive center tests, idempotence, reversal, invalid tools, allocation-failure injection, preservation of the shank and core, and removal at the flutes and tip.
- The final geometry and an intermediate frame from the actual encoded MP4 were visually inspected. The entire MP4 was independently decoded without errors; format, resolution, frame count, and duration were checked.
