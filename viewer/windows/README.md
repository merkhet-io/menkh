# Windows D3D12 voxel viewer

Standalone C++17 / Windows SDK viewer. It reads the existing Zig engine's
`menkh-voxel-history-v1` JSON plus `initial.blocks`, `initial.pool` and deltas.
It can also calculate JSON jobs using the engine DLL or CLI, then open the result.
Recorded-history playback needs neither the engine nor Zig; building the viewer
requires only MSVC and the Windows SDK.
Keep the history directory intact when transferring it to another computer.

The CI artifact includes `menkh-windows-viewer-demo.zip` after rendering tests
pass. Extract that nested ZIP and double-click `open-demo.bat` to play the 25 µm
pocket example without installing a compiler. To bundle another recorded job:

```sh
python scripts/package-windows-viewer.py --binary-dir out/windows-viewer --history out/windows-pocket/voxel-animation.json --out out/menkh-windows-viewer-demo.zip
```

## Build and run

With Visual Studio C++ desktop tools and the Windows SDK already installed:

```bat
viewer\windows\build.bat
out\windows-viewer\menkh-viewer.exe out\windows-pocket\voxel-animation.json
```

The batch file discovers installed MSVC using `vswhere` if necessary. It installs
nothing. Alternatively open `menkh-viewer.vcxproj` in Visual Studio 2026, select
Release/x64, and build. The project uses toolset v145; its executable and shader
are in `out/windows-viewer/Release`. `build.bat --project` invokes that project.
Keep `Voxel.hlsl` beside the executable. Both builds use the Windows SDK shader
compiler (`d3dcompiler_47.dll`), not a separately installed DXC or Vulkan SDK.

To create the pocket history from the repository root with the existing engine:

```powershell
.\zig.ps1 build -Doptimize=ReleaseFast
.\zig-out\bin\menkh.exe job examples/pocket-25um.json --out out/windows-pocket
.\out\windows-viewer\menkh-viewer.exe out/windows-pocket/voxel-animation.json
```

The viewer can also load the existing 4096³ drill's voxel history. That resolution
has a substantially larger CPU/GPU memory requirement; no Windows hardware FPS
or full-resolution drill rendering claim is made by the small WARP smoke test.
It does not read the older OBJ-only `animation.json` format.

## Controls

- Left drag: orbit; right drag: pan; wheel: zoom; **R** or Reset: reset camera.
- Play/Pause or **Space**: playback; slider: scrub in either direction.
- **Left/Right**: one operation; **Home/End**: initial/final state.
- **B**: orange/dark background; **T**: cutter/shank/holder visibility.
- **A**: four-sample display antialiasing; **[ / ]**: lower/raise Z section.

Playback advances at most one recorded operation every 80 ms. Slow rendering
slows playback instead of skipping operations. Playback duration is not machining
time or a simulation benchmark. Surfaces remain voxel-stepped; antialiasing does
not alter occupancy or material metrics.

## Rendering and boundaries

D3D12 compute traverses the block grid and occupancy words directly. Empty blocks
are skipped, and only the first visible occupied cell contributes stock shading.
There is no cube draw call per voxel and no mesh generation requirement. Tool
cylinders are display geometry; the renderer never changes material occupancy.

The initial buffers are uploaded once. Subsequent history changes update only
coalesced descriptor/pool byte ranges in default-heap GPU buffers. A fence permits
only one in-flight frame, preventing staging/history updates from racing rendering.
This first implementation prioritizes correctness over pipelined frame throughput.

Supported tool visualization is the flat cutter plus cylindrical shank/holder.
For non-flat cutters the status explicitly says cutter display is unavailable;
the recorded stock remains visible. Target/gouge coloring, fixture display,
picking, toolpath overlays, video encoding and lighting-normal smoothing are not
implemented in this viewer. The macOS viewer remains available unchanged.

## Validation and troubleshooting

```bat
out\windows-viewer\menkh-viewer.exe HISTORY.json --verify-history
out\windows-viewer\menkh-viewer.exe HISTORY.json --warp --smoke out\viewer-smoke
out\windows-viewer\menkh-viewer.exe HISTORY.json --warp --window-smoke out\viewer-smoke
out\windows-viewer\menkh-viewer.exe HISTORY.json --frame 325 --snapshot final.ppm
```

`--verify-history` needs no graphics device. It checks initial/final material
counts and byte-exact descriptor/pool restoration through forward/backward/replay.
Invalid dimensions, counts, paths, truncated records, state mismatches, invalid
boundary bits and aliased pool slots are rejected. Changes validate and reserve
memory before mutating each delta; a seek consisting of several deltas may stop
at the last successful delta if a later file is corrupt.

`--warp` explicitly selects Microsoft's D3D12 software renderer. It is useful
for validation or diagnosing a driver problem, not representative of hardware
performance. Normal operation selects a hardware adapter and reports an error
if no D3D12 device is available. `--debug` requests the optional Windows D3D12
debug layer; it fails clearly if that OS component is not installed.

CI builds the batch and Visual Studio project, verifies actual 25 µm history,
rejects malformed inputs, renders initial/middle/final/rewound images and checks
byte-identical rendered rewind. The window smoke also exercises swapchain resize,
slider scrubbing and Home/End keys. Executable, shader and PPM evidence are retained
in the `windows-d3d12-viewer` artifact. Manual mouse interaction and discrete-GPU
performance require testing on a Windows workstation.

The only vendored dependency is nlohmann/json **3.12.0**, MIT license in
`vendor/LICENSE.json`. Its upstream single-header SHA-256 is
`aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63`.
It is entirely outside the Zig simulation core. Upstream:
https://github.com/nlohmann/json/releases/tag/v3.12.0

## Default drill demo

```powershell
./zig-out/bin/menkh.exe drill --voxel 0.1 --out out/drill
./out/windows-viewer/menkh-viewer.exe out/drill/animation.json
```

Current drill outputs include a matching voxel history; the Windows reader follows
its explicit manifest reference. `out/drill/voxel-animation.json` also opens
directly. Regenerate older mesh-only output with the current CLI. Rendering remains
voxel-based; this does not add a mesh renderer or a spherical demo-tool display.

### Exposure colors during playback

Generate a job with `"export_provenance": true` and
`"provenance_scope": "all_frames"`, then open its history with
`--color-operation` or `--color-tool`. Press **C** to cycle material, operation
and tool colors while staying at the current frame. Colors remain active during
playback and reverse scrubbing. The default `final_surface` scope retains the
older final-frame-only behavior. Initial/prehistory faces and section interiors remain neutral.

The metadata reader validates grid/origin/spacing, operation IDs, sorted 64-bit
cell keys and tool mappings. Rendering looks up the removed neighbor of the hit
voxel face, not the last operation touching the surviving voxel. Keys retain all
36 bits needed for a 4096³ grid. This is categorical coloring, not a removal-rate
heatmap. Windows picking remains unsupported. See the [index limits and measurements](../../docs/SURFACE-PROVENANCE.md).

### In-process job calculation

Build the library with `.\zig.ps1 build sdk -Doptimize=ReleaseFast` before building the
viewer. If `menkh.dll` is beside the viewer, opening a job uses it on a background
thread. Select a different library with `--library PATH`, or explicitly retain
the process runner with `--engine PATH`. Progress/cancellation and automatic
result loading are available in either mode; library cancellation waits for the
current operation boundary. The DLL remains loaded until its worker exits.
See [the API contract](../../docs/C-API.md). This does not yet provide live
material inspection while calculating.
