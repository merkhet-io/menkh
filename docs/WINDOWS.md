# Windows engine and viewer

The Zig engine, CLI, checkpoint inspection and CPU predicate benchmark have an
experimental Windows x86-64 build. The Swift/Metal viewer remains macOS-only; a separate [D3D12 viewer](../viewer/windows/README.md) now reads the same voxel history on Windows.
Zig builds the engine and its shared/static C libraries. MSVC builds the viewer,
which can load the engine DLL to calculate jobs in process. Building only the Zig
CLI does not require Visual Studio; building the native viewer requires the C++
desktop tools and Windows SDK.

## Screw grinding without shell scripts

After building the CLI, the workload generator and simulator are both native:

```powershell
.\zig-out\bin\menkh.exe grinding-demo --voxel 0.1 --out out/screw
.\out\windows-viewer\menkh-viewer.exe out/screw/result/voxel-animation.json
```

Use a fresh output directory; `--voxel 0.025` requests 25 µm spacing.
`--generate-only` writes a reusable JSON job without running it. The
[two-start screw protocol](SCREW-GRINDING.md) records geometry, continuous-motion
approximations, benchmark commands and the unsupported 16k³ world case.
The recorded piecewise-conical wheel profile is now drawn by the viewer.
Optional `--smooth-lighting` (or **L**) averages lighting normals during playback;
voxel geometry and exposure colors remain unchanged. Native D3D12 validation
for these changes is covered by CI; local macOS checks do not establish Windows runtime success.

## Native viewer

The separate C++17 viewer uses D3D12 and reads the engine's voxel history.
Build it with `viewer\windows\build.bat` or open
`viewer/windows/menkh-viewer.vcxproj` in Visual Studio 2026 (v145, Release/x64).
Start it with:

```powershell
.\out\windows-viewer\menkh-viewer.exe out/windows-pocket/voxel-animation.json
```

For playback without a compiler, download the `windows-d3d12-viewer` CI artifact,
extract its `menkh-windows-viewer-demo.zip`, then run `open-demo.bat`.
The demo ZIP is produced only after rendering and window smoke tests pass.
See the [viewer instructions](../viewer/windows/README.md) for camera controls,
scrubbing, Z sections, software rendering and limitations.

![25 µm pocket rendered by the Windows D3D12 viewer](windows-viewer.png)

This viewport image was rendered by D3D12 WARP on Windows and visually inspected.
It demonstrates rendering, not hardware-GPU throughput. The stepped surface and
face-normal shading display the voxel grid without changing material occupancy.

## Zig CLI

From a PowerShell terminal in the repository:

```powershell
.\scripts\bootstrap-zig.ps1
.\zig.ps1 build -Doptimize=ReleaseFast
.\zig.ps1 build test --summary all
.\zig.ps1 build test -Doptimize=ReleaseFast --summary all
.\zig-out\bin\menkh.exe job examples/pocket-25um.json --out out/windows-pocket
.\zig-out\bin\menkh.exe inspect-state out/windows-pocket/final.menkh
.\zig.ps1 build kernel-bench -Doptimize=ReleaseFast > out/predicate-benchmark.json
```

The bootstrap downloads the pinned Zig 0.15.2 archive into `.tools`, verifies its
SHA-256 against the [official download index](https://ziglang.org/download/index.json),
and changes no global installation or PATH. The checked-in pocket job requires
no Python. It is the 325-segment 25 µm video job with mesh export disabled.

Native Windows builds use the host target/CPU. To make portable x86-64 binaries,
pass `-Dtarget=x86_64-windows -Dcpu=baseline`. For performance comparisons on Jens'
Ryzen, use a native build on that machine and record the emitted CPU model.
Do not assume a particular AVX-512 instruction sequence from `@Vector(8, f64)`:
the compiler selects instructions for the requested CPU.

Windows memory reports use peak working-set bytes via Zig's process memory API;
macOS uses peak RSS bytes. Those OS counters are related measurements, not an
identical cross-platform accounting contract. Query failures are errors, not zero
memory readings. Cutting and storage formats do not depend on the platform module.

Validation: the CLI and kernel benchmark were cross-compiled on macOS. The
`windows-cli` GitHub Actions job builds and executes Debug/ReleaseFast tests and
the 25 µm pocket plus exact remaining-material/surface-count checks. Consult its
run result before treating Windows runtime validation as complete. The engine exposes a [versioned C ABI](C-API.md) in Zig-built shared/static
libraries. CI also runs independent C hosts, compares DLL job output with the CLI,
and tests viewer cancellation and automatic result rendering. The separate
D3D12 viewer has a `build.bat` and v145 `.vcxproj`; recorded playback does not
require Zig or an engine library.

## Calculate through the viewer

Build the DLL before the viewer so the batch/project build copies it beside the
executable:

```powershell
.\zig.ps1 build sdk -Doptimize=ReleaseFast
.\viewer\windows\build.bat
.\out\windows-viewer\menkh-viewer.exe examples/pocket-25um.json --job-output out/windows-pocket-new
```

The adjacent DLL is selected automatically. `--library PATH` chooses a DLL;
`--engine PATH` explicitly chooses the supervised CLI subprocess instead.
The UI stays responsive while the library runs on a worker thread. Cancellation
waits for the current operation boundary. Add `--live` for leased material windows,
Follow latest/hold, scrubbing and calculation pause/resume. Live mode also uses
cooperative cancellation with the subprocess runner. The completed result opens
automatically after success. See [live controls and measurements](LIVE-INSPECTION.md). Output directories
must be new. For static embedding, build `sdk-static` and follow the
[C host examples and ownership contract](C-API.md).

## Diagnose screw-grinding time

```powershell
.\scripts\summarize-grinding.ps1 out/screw/result/report.json
```

This reads the recorded phase timings without repeating the simulation. Include
the CPU model and source commit when sharing it. The new optional
`grinding-demo --workers 8` requests up to eight CPU workers; default is one.
See [grinding performance](GRINDING-PERFORMANCE.md) for comparable settings
and the distinction between voxel spacing and display lighting.
