![Menkh — an orange chisel cutting a blue voxel block](docs/brand/menkh.svg)

# Menkh — geometric cutting simulation

Menkh calculates the material remaining after machining. Its **Zig CPU engine**
runs on **macOS / Apple Silicon** and **Windows x86-64**, with native
**Swift/Metal** and **C++/D3D12** voxel viewers. General machining jobs use binary
voxel material; a separate experimental grinding kernel stores **continuous
material intervals on sampled XY rays**. Lean proofs cover selected mathematical
models, and a versioned C API supports embedding the voxel engine.

[Get started](#get-started) · [Grinding](#helical-screw-grinding) · [Windows guide](docs/WINDOWS.md) · [C API](docs/C-API.md) · [Capabilities](docs/CAPABILITIES.md) · [Changelog](CHANGELOG.md)

| Workflow | Material representation | Inspection and persistence |
|---|---|---|
| General jobs, `grinding-demo`, `drill` | 8³ voxel blocks with pooled occupancy bits | Native voxel playback, reversible history, job checkpoints, supported inspection tools |
| Experimental `raydexel-bench` | Continuous Z intervals on XY rays; no Z voxel subdivision | Final-state binary dump, PPM sections and derived OBJ; no history, resume or native interval animation |

Toolpath generation, controller emulation, full machine kinematics and physical
force/thermal simulation are outside the product boundary. All cutting runs on
the CPU. GPU APIs provide rendering.

## Helical screw grinding

Both grinding paths use a 12 × 40 mm cylindrical blank, a finite profiled wheel
and 1,024 continuous XYZAC segments to form a two-start screw. Motion is covered
conservatively between tool poses. The workload is an idealized grinding example,
not a certified thread profile or evidence of industrial simulator parity.

### Fast final-state experiment

After [building the CLI](#get-started), run the current symmetry-aware method:

```sh
zig-out/bin/menkh raydexel-bench --method axis --spacing 0.025 --tolerance 0.01 --workers 8 --out out/screw-rays-25um
```

On Windows:

```powershell
.\zig-out\bin\menkh.exe raydexel-bench --method axis --spacing 0.025 --tolerance 0.01 --workers 8 --out out/screw-rays-25um
```

Use a new output directory for each run. `--spacing` sets the **XY ray spacing in
millimeters**; endpoints along Z remain continuous. `--tolerance` separately
controls the motion approximation. `--method axis` is opt-in: the default remains
`fixed`, and the independently tested `adaptive` method remains available.

The current implementation:

- Intersects the complete convex wheel profile analytically with each ray.
- Uses rotational symmetry and true-time midpoint poses to reduce preparation
  from **90,112 to 39,936 poses** at the same requested 10 µm motion budget.
- Selects tighter group enclosures to skip more overlapping cuts, preserving
  cutter geometry, traversal order and final material.
- Processes disjoint rays with deterministic CPU workers and stores long material
  spans as intervals rather than individual volume voxels.

**Latest matched measurements:** M5 Max, 128 GiB, Zig 0.15.2 ReleaseFast, eight
workers; one warm-up and five measured runs per configuration, alternating the
old and improved group-enclosure kernels.

| XY spacing | Previous cutting median | Current cutting median |
|---|---:|---:|
| 250 µm | 0.03988 s | **0.03188 s** |
| 100 µm | 0.33121 s | **0.28406 s** |
| 50 µm | 1.35656 s | **1.11647 s** |
| 25 µm | 5.53682 s | **4.60302 s** |

At 25 µm, the current range is **4.499–4.920 s**, kernel total median is **4.625 s**,
and peak process RSS is **50.18 MB**. Fine ray/pose queries fall from **359.6 to
282.1 million**. Complete interval files are **byte-identical before and after
this optimization at all four spacings**. These are no-history cutting/kernel
measurements, excluding mesh generation and viewer loading; they are not voxel
tests-per-second or interactive FPS. See [raw results, ranges and reproduction](docs/evidence/ray-envelope-anchors/README.md).

The earlier change from `fixed` to `axis` is different: it changes the conservative
motion approximation. Their reported motion bounds are 8.48 and 9.81 µm,
respectively, within the requested 10 µm budget. At 25 µm, `axis` removed an
additional 4.22 mm³ in the frozen example; that difference is documented rather
than treated as identical geometry. A separate stricter-bound run also completed.
See [motion derivation and limits](docs/ANALYTIC-DEXELS.md) and
[planner comparisons, accuracy tests and noisy runs](docs/evidence/axisymmetric-rays/README.md).

A complete **6.25 µm** run was also performed with the earlier **fixed** method:
122.52 s cutting and 676.32 MB kernel peak RSS. That is a historical qualification,
not a measurement of the latest `axis` kernel. Its 10 µm motion budget remained
separate from ray spacing. [Evidence](docs/evidence/analytic-dexels/README.md).

### Inspect an interval result

The CLI writes `job.json`, `report.json`, `intervals.json` / `intervals.bin`, and
PPM sections through the workpiece. Validate a saved result with:

```sh
python3 scripts/inspect-raydexels.py out/screw-rays-25um/intervals.json --check-screw-invariants
```

For a manageable macOS mesh preview, generate a coarser result and export its
actual column surface:

```sh
zig-out/bin/menkh raydexel-bench --method axis --spacing 0.1 --workers 8 --out out/screw-preview
python3 scripts/export-raydexel-obj.py out/screw-preview/intervals.json out/screw-preview/surface.obj --validate-edges
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/screw-preview/surface.obj --hide-path
```

![Actual 100 µm interval result, inspected in the native macOS viewer](docs/evidence/axisymmetric-rays/100um-axis-column-solid.png)

This is the **100 µm column-solid preview**, without geometric smoothing. The OBJ
viewer fits the actual mesh bounds; `--hide-path` hides the unrelated legacy groove
annotation. Mesh export and loading can cost more than cutting. The exporter
limits input to 256 MiB. Python is needed for these optional inspection scripts,
not for the cutting CLI.

The interval experiment currently supports convex profiled tools and cylindrical
stock. It is **not tri-dexel storage** and has no STL stock import, resume, history
or native interval playback. The Windows CLI can calculate it, but the Windows
viewer does not load its interval dumps or OBJ previews. Use the voxel workflow
below for animated inspection on either platform.

### Grinding with playback and exposure colors

```sh
zig-out/bin/menkh grinding-demo --voxel 0.1 --workers 8 --out out/screw-history
```

Open `out/screw-history/result/voxel-animation.json` in the native viewer:

```sh
# macOS
zig-out/bin/menkh-viewer out/screw-history/result/voxel-animation.json --color-operation
```

```powershell
# Windows, after building the viewer
.\out\windows-viewer\menkh-viewer.exe out/screw-history/result/voxel-animation.json --color-operation
```

Use `--voxel 0.025` for 25 µm voxel spacing and another fresh output directory.
This path retains reversible history and operation-exposure provenance, so its
runtime and memory are not interchangeable with `raydexel-bench` results.
The generator is native Zig on both platforms. See the
[screw protocol](docs/SCREW-GRINDING.md), [worker measurements and viewer details](docs/GRINDING-PERFORMANCE.md).
The older [quantized dexel experiment](docs/DEXEL-EXPERIMENT.md) remains an exact
occupancy comparison and was slower; it is distinct from the continuous kernel.

## Get started

### macOS / Apple Silicon

With Apple Command Line Tools installed:

```sh
./scripts/bootstrap-zig.sh
./zig build -Doptimize=ReleaseFast
./scripts/general-demo.sh
```

The repository pins **Zig 0.15.2** locally in `.tools/`; no global installation is
required. `./zig build` uses Debug by default. CLI builds and tests do not require
the viewer. `./scripts/build-viewer.sh` builds the separate native macOS app.
See [build/SDK details](docs/BENCHMARKS.md) if the installed macOS SDK is incompatible;
`MENKH_SDK=/path/to/MacOSX.sdk ./zig build` selects an existing SDK without changing
system settings.

### Windows x86-64

For playback without compiling, download **windows-d3d12-viewer** from a successful
[Verification run](https://github.com/merkhet-io/menkh/actions/workflows/verification.yml),
extract `menkh-windows-viewer-demo.zip`, and run `open-demo.bat`.
`calculate-demo.bat` runs the bundled job. Keep the extracted files together.

Build from PowerShell, with Visual Studio C++ desktop tools and the Windows SDK
installed for the viewer:

```powershell
.\scripts\bootstrap-zig.ps1
.\zig.ps1 build -Doptimize=ReleaseFast
.\zig.ps1 build sdk -Doptimize=ReleaseFast
.\viewer\windows\build.bat
.\out\windows-viewer\menkh-viewer.exe examples/pocket-25um.json --job-output out/windows-pocket
```

Zig builds the engine; MSVC builds the viewer. Alternatively, open
`viewer/windows/menkh-viewer.vcxproj` in Visual Studio 2026, toolset **v145**,
Release/x64. The viewer uses the adjacent `menkh.dll` on a worker thread;
`--library PATH` selects another DLL and `--engine PATH` selects the CLI runner.
Use a new `--job-output` directory for each calculation.

Both native voxel viewers support orbit/zoom, playback and scrubbing. Windows
also supports pan, XYZ sections, target/fixture overlays and picking, but has fewer
inspection features than macOS. **C** cycles exposure colors when provenance is
available. [Windows setup](docs/WINDOWS.md) · [Controls and limits](viewer/windows/README.md).

Windows CI checks MSVC builds, DLL/static-library integration, CLI equivalence,
cancellation, shader compilation and D3D12 WARP rendering/replay. WARP establishes
functionality, not hardware-GPU performance. New interval algorithms are also
cross-built locally and covered by the portable CLI test suite.

## General machining and inspection

General JSON jobs support primitive or closed binary-STL stock/targets,
fixed-orientation flat/ball/bull/taper cutters, bounded circular/helical motion,
checkpoints, reversible history, fixture/holder checks and target comparison.
Fixed-axis line jobs reject orientation changes; wheel XYZAC motion has its own
bounded-sweep contract. Limited turning envelopes are geometric operations, not
a complete mill-turn machine simulation.

```sh
zig-out/bin/menkh job examples/general.json --voxel 0.1 --out out/general
zig-out/bin/menkh inspect-state out/general/final.menkh
zig-out/bin/menkh-viewer out/general/voxel-animation.json --color-operation
```

`--voxel MM` overrides job spacing for stock, target and fixtures without rewriting
the input JSON. Resumed states must match that grid. Voxel surface counts are
reported separately from occupied volume voxels; [definitions and comparison limits](docs/INSPECTION-COUNTS.md)
explain why these are not interchangeable with ray or predicate counts.

- **Live inspection:** add `--live` when opening a job in either native viewer.
  Follow the latest completed operation, hold/scrub retained states, pause/resume
  calculation and cancel. [Live inspection](docs/LIVE-INSPECTION.md),
  [overlays and picking](docs/LIVE-OVERLAYS.md).
- **Exposure colors:** identify the operation/tool that exposed a face, not
  geometric accuracy or removal rate. General jobs export playback-wide
  provenance by default. Use `--provenance final_surface` or `--no-provenance`
  to reduce attribution storage. [Color semantics](docs/SURFACE-PROVENANCE.md).
- **Defects and collisions:** the macOS inspector filters excess/missing regions,
  focuses findings and seeks collision operations. Reports can be regenerated
  from saved material. [Inspector](docs/DEFECT-INSPECTOR.md).
- **Scenes:** `./scripts/scene-demo.sh` exercises named geometry/tool resources and
  independent translated workpieces. Both viewers open the resulting scene
  catalog with `--workpiece ID`. It is not yet a combined assembly viewport or
  inter-workpiece collision simulation. [Scene contract](docs/SCENES.md).

[Watch the inspected pocket-milling video](docs/general-demo.mp4) · [Capability matrix](docs/CAPABILITIES.md)

### Imported ball-end finishing

```sh
python3 scripts/finishing-workflow.py --smoke
python3 scripts/finishing-workflow.py
```

This frozen experiment imports distinct closed STL stock and target, runs **5,199
ball-end segments at 25 µm**, compares the result, validates checkpoint/compacted
resumption and saves native inspection images. The smoke configuration uses the
same geometry/path at 250 µm. The recorded robustness milestone completed in
**21.75 s total**, **15.57 s cutting**, with **121.27 MB peak RSS** on the M5 Max.
These are that milestone's measurements, not a rerun after every commit.
[Protocol](docs/FINISHING-PROTOCOL.md) · [Implementation](docs/FINISHING-ARCHITECTURE.md) · [Results](docs/MILLING-ROBUSTNESS.md).
`python3 scripts/clamped-finishing.py` adds low-clamp and deliberately colliding
fixture cases; contact reports do not stop or reroute the path.

### Embed the voxel engine

Build `sdk` for a shared library or `sdk-static` for a static library. The
[versioned C API](docs/C-API.md) exposes material operations, queries, copied-history
undo/redo, checkpoint/resume and JSON jobs with progress/cancellation. Rendering
remains separate. The experimental ray-interval command is not exposed through
this API.

## Accuracy and representation

| Backend | Material and volume semantics |
|---|---|
| Voxel jobs | Occupancy is sampled at voxel centers; volume is occupied cells × voxel volume. Pooled 8³ blocks retain disconnected pieces and enclosed cavities. |
| Continuous ray experiment | Each XY cell samples a continuous Z interval set; volume is summed interval length × XY cell area. Features between rays can be missed. OBJ export assigns each ray its square transverse cell. |

Input tessellation, toolpath approximation, continuous-motion bounds, occupancy
sampling and surface reconstruction are separate error sources. **25 µm spacing
is not a guaranteed 25 µm maximum surface error.** A small volume difference is
not proof of local accuracy. Normal smoothing changes lighting only; adaptive
simulation resolution and viewer LOD are not implemented by the new ray kernel.

The current dense voxel world has resource limits; the
[sparse mutation experiment](docs/SPARSE-MUTATION.md) is a separate backend.
A virtual 65,536³ coordinate domain is not proof that a fully populated surface
of that scale fits memory. [Large-world qualification](docs/LARGE-WORLD-QUALIFICATION.md).
There is no established matched performance ratio against Jens or ModuleWorks.

## Tests and reproducible measurements

```sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
python3 scripts/test-raydexels.py --out out/ray-tests-new
python3 scripts/benchmark-raydexels.py --methods fixed axis --out out/ray-bench-new
```

The ray suite includes independent geometry checks, exhaustive small-grid
comparisons, allocation failures, exact worker determinism, interval validation,
retained core/endcaps and mesh volume/edge checks. Benchmark outputs retain
warm-ups, repeated timings, configuration/source/binary identifiers and material
hashes. The [latest comparison](docs/evidence/ray-envelope-anchors/README.md)
provides the command for comparing two compiled binaries byte for byte.

Other recorded workloads include the 325-segment pocket: **2.43 ms cutting at
100 µm**, and **60.65 ms at 25 µm** with 117.08 ms full CLI time when mesh export
was disabled. These are historical ReleaseFast measurements of that specific
voxel workload, not numbers for screw grinding. [CPU evidence](docs/CPU-PERFORMANCE.md).

## Formal verification with Lean

**34 named, machine-checked Lean results** cover selected mathematical models:
finite-cylinder straight sweeps in real arithmetic; subtraction monotonicity and
idempotence; removed/remaining partitions and restoration; and abstract pool
ownership/history rules under explicit preconditions. Additional results support
block classification under stated hypotheses.

CI audits the proofs and their axioms and compares **20,480 Lean-generated
records** with Zig in Debug and ReleaseFast. Negative controls check that broken
subtraction, undo and pool updates fail verification.

These are **model proofs plus implementation tests**, not a proof of the compiled
Zig engine. The continuous ray kernel, axisymmetric planner and new group-envelope
optimization are outside the formal model, as are floating-point rounding and
surface reconstruction. Lean is separate from engine/viewer builds.

```sh
./scripts/bootstrap-formal.sh  # Requires existing elan; toolchain stays in .tools/
./scripts/verify-formal.sh
```

[Theorem inventory, assumptions and reproduction](docs/FORMAL-VERIFICATION.md).

## Original demos

These supported demos retain their own protocols, media and historical measurements.

| Demo | Command / guide |
|---|---|
| 40 × 30 × 10 mm capsule groove | `./zig build demo -- --voxel 0.25 --out out/groove` · [Architecture](docs/ARCHITECTURE.md) · [Original benchmarks](docs/BENCHMARKS.md) |
| Twist drill from cylindrical stock | `./scripts/drill-demo.sh` · [Animation](docs/drill-demo.mp4) · [Guide](docs/DRILL-DEMO.md) |
| Exact 4096³ voxel domain | `./scripts/drill-4096.sh` · [Animation](docs/drill-4096.mp4) · [Protocol and measurements](docs/VOXEL-4096.md) |
| Profile-wheel grinding | `./scripts/grinding-demo.sh --profile` · [Wheel and motion contract](docs/GRINDING.md) |

The default `drill` command emits `voxel-animation.json` for both native viewers;
its `animation.json` retains the macOS mesh animation and routes Windows to the
matching voxel history. Regenerate older mesh-only outputs once.

The original groove's `demo`, `export` and `bench` commands remain available.
They emit PPM height images, exposed-face OBJ meshes and JSON reports;
`--no-mesh` skips mesh generation and `--reference` selects scalar cutting.
`export` reruns that fixed scenario rather than loading an arbitrary state.
See [formats](docs/FORMATS.md), [engine contracts](docs/ENGINE.md) and the
[product roadmap](docs/PRODUCT-ROADMAP.md) for broader workflows and remaining gates.

## Why Zig?

Menkh started as a chance to learn Zig by building a cutting simulator with coding
agents. Zig also fits the practical demands of this engine:

- **Control over memory.** Explicit allocators let us reserve storage before a
  cut, keep voxel bits in contiguous pools, and avoid allocations in the inner
  cutting loop. Memory use matters as much as arithmetic at fine resolutions.
- **Direct data representation.** Integer types, bitwise operations, `@popCount`
  and `@Vector` suit compact occupancy grids and CPU kernels. The implementation
  keeps material in arrays and pooled blocks rather than per-voxel entities.
- **Explicit failure handling.** Error unions and `defer`/`errdefer` help make
  invalid geometry, capacity limits and allocation failures visible, with cleanup
  close to the code that owns each resource.
- **One engine toolchain.** The repository pins Zig and uses `build.zig` for the
  CLI, tests, benchmarks and libraries on macOS and Windows. Native viewers stay
  in Swift/Metal and C++/D3D12, connected through files or the versioned C API.

Zig gives us useful control; the algorithms and data layout determine whether we
use it well. Performance claims come from measured workloads and comparison with
reference implementations, not from the language choice alone.

## Why “Menkh”?

**𓍊 — a chisel.** The name draws on ancient Egyptian *mnḫ*, associated with carving. We chose it because the simulator does the same basic job as a chisel: remove material to give a workpiece its shape. The sign **𓍊** is Gardiner **U22** (Unicode U+1334A), used in writing *mnḫ*. “Menkh” is our readable Latin spelling, not a claim about the exact ancient pronunciation. The logo pairs a chisel with a voxel block.

Sources: [Gardiner sign list, U22](https://www.egyptianhieroglyphs.net/gardiners-sign-list/) and the Metropolitan Museum’s [*Ancient Egyptian Calligraphy*](https://resources.metmuseum.org/resources/metpublications/pdf/Ancient_Egyptian_Calligraphy.pdf), entry U22.

## License

Menkh is licensed under the [MIT License](LICENSE).
Third-party components retain their own copyright and license notices,
including [nlohmann/json](viewer/windows/vendor/LICENSE.json) in the Windows viewer.
