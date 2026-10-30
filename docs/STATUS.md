# Project state

The current general-engine milestone is documented in the [capability matrix](CAPABILITIES.md), [architecture and numerical contracts](ENGINE.md), [formats](FORMATS.md), and [validation report](ENGINE-VALIDATION.md). Start it with `./scripts/general-demo.sh` or run `./zig build job -Doptimize=ReleaseFast -- examples/general.json --out out/general`.

General jobs now support explicit origins, analytic stock unions, binary STL stock/targets, fixed-orientation tools and motion, bounded arcs/helices, geometric collision reports, target comparison, sections, checkpoints, and reversible native playback. Limited full-revolution turning envelopes operate on the same material state. Simultaneous 5-axis orientation changes are explicitly unsupported. No industrial parity, certified clearance, or production mill-turn claim is made.

The rest of this page records the original saved checkpoint. Its test counts and measurements are historical; current evidence is in the validation report. Existing demo media and the original CLI remain available.

## Included features

| Entry point | Features |
|---|---|
| `./zig build demo` / `export` | Cuboid stock, vertical end mill, continuous XY capsule sweep at constant Z; scalar reference and block-based optimization; PPM, OBJ, and JSON |
| `./zig build bench -Doptimize=ReleaseFast` | Reference comparison, warm-up, repetitions, and separate phase timings |
| `./scripts/drill-demo.sh` | Cylindrical blank, two helical flutes, and simplified tip faceting; 225 voxel-surface mesh states with an animated tool |
| `./scripts/drill-4096.sh` | Exactly 4096 × 4096 × 4096 grid cells in a 60 mm cube; 14.6484375 µm voxels; CPU cutting, reversible block changes, and direct Metal rendering |
| Viewer | Pause, restart, timeline slider, orbit, and zoom; Metal mode also provides pan and surface focus by double-clicking |

Material is stored as compact descriptors for 8³ blocks and a contiguous pool of 512-bit occupancy fields. CPU geometry predicates use `f64`; the renderer uses `f32`. The Metal shader reads the material state and does not perform material removal. There is no octree, explicit SIMD, or multiworker optimization.

## Restore and run

The only supported platform is macOS on Apple Silicon. Development used Zig **0.15.2**, Apple Command Line Tools, the already installed macOS 15.4 SDK for Zig, and Apple Swift for the viewers. The project-specific SDK wrapper is explained in the [README](../README.md).

```sh
./scripts/bootstrap-zig.sh        # Local toolchain in .tools/, verified with SHA-256
./zig build
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
./zig build -Doptimize=ReleaseFast
./scripts/drill-4096.sh
```

The toolchain, compiler caches, binaries, and large regenerable simulation files in `.tools/`, `.zig-cache/`, `zig-out/`, and `out/` are intentionally excluded from Git. The scripts regenerate them. No global dependencies were installed. Existing macOS SDKs and system frameworks are prerequisites, not bundled packages.

## Validation and evidence

The following checks were rerun before the initial code commit:

- **17/17 test groups passed in both Debug and ReleaseFast**.
- The ReleaseFast CLI and native viewer built successfully.
- Zig formatting and shell script syntax checks passed.

The following were also run and documented during implementation:

- A 25 µm cuboid run and benchmarks at all four original grid spacings, checked voxel by voxel against the reference.
- Independent PPM/OBJ validation, including oriented mesh volume.
- The exact 4096³ demo: 2,159,116,288 initially occupied voxels and 1,333,399,870 after cutting.
- Forward, backward, and forward replay of the full-size dataset; initial descriptors and original bit fields were byte-identical after rewinding.
- Both demo videos were rendered, fully decoded, and checked using intermediate and final images.

Measurements are described in the [benchmark report](BENCHMARKS.md) and [4096³ report](VOXEL-4096.md); raw data is in [`benchmarks/`](../benchmarks/). The 4096³ report separates total generation, CPU cutting, file export, and GPU rendering time. Historical measurements are recorded results, not guarantees that every checkout will reproduce the same timings.

## Known limitations

- Center-sampled occupancy and `voxel count × h³` volume are raster approximations. Grid spacing is not a guaranteed maximum surface deviation.
- The drill is an idealized geometry demo, not a production-validated cutting tool or NC program. Holder collisions and machine kinematics are not modeled.
- The animation replays precomputed material states or block changes; simulation and rendering are not yet coupled live.
- Optional normal averaging in Metal mode affects lighting only. It leaves occupancy and contours unchanged and can be disabled in the viewer.
- There is no guaranteed interactive frame rate, general CAD/G-code import, or signed macOS app bundle.
- The older mesh viewer uses SceneKit; the newer voxel renderer uses Metal/MetalKit directly.

The [architecture documentation](ARCHITECTURE.md) describes coordinates, memory management, conservative geometry checks, and error behavior. The initial PR description summarizes this checkpoint for review.
