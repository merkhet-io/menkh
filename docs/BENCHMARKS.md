# Measured benchmarks

Measured on October 29–30, 2026, on a **MacBook Pro Mac17,6, Apple M5 Max, 18 CPU cores (6 Super + 12 Performance), 128 GB RAM, macOS 27.0.1**. Native aarch64-macos binary, Zig **0.15.2**, **ReleaseFast**, **one worker**. On this hardware, this Zig version resolves `-mcpu=native` to `apple_m1` with native feature flags. This describes compiler detection, not the physical CPU model. Zig uses the existing macOS 15.4 SDK; the viewer uses Apple Swift 6.3.2.

All figures come from completed runs. Raw data are in [`../benchmarks/`](../benchmarks/), with hardware and build details in [`environment.json`](../benchmarks/environment.json). The tables contain the final complete measurement series for the original core implementation; preliminary development measurements may differ.

## Method

Fixed stock: 40 × 30 × 10 mm; cutter radius: 3 mm; cutting length: 10 mm; segment: (10,15,6) → (30,15,6). Every repetition initializes fresh, identical stock. An additional untimed **voxel-exact comparison of all block bits** between reference and optimized implementations runs first. Each implementation then receives one complete warm-up and seven measured repetitions. The reference runs first, followed by the optimized version, with identical scenarios, storage, pool preparation, surface generation, and export. No thread affinity, isolated machine, or constant temperature and clock rate is guaranteed.

Timing uses the monotonic nanosecond `std.time.Timer`, with separate phases. Cutting includes pool preparation and reservation. Statistics, surface generation, and PPM/OBJ export are outside cutting time. Export includes PPM generation, text serialization, and file writes, but **no fsync**; this measures the warm macOS filesystem path, not durable SSD persistence. JSON serialization, analytical validation, and resource queries are outside these phase timers. The benchmark additionally validates each repetition's removed voxel count against a complete XY-column count for the example and compares every repetition with the warm-up. Results are checked and reported, preventing them from being optimized away.

## Material removal

All times are in ms, with min–max ranges. Both implementations run scalar code with one worker and no explicit `@Vector`. The reference is already bounded to candidate blocks; it does not artificially scan the entire stock.

| Grid spacing mm | Reference median (min–max) | Block-mask median (min–max) | Measured median ratio |
|---:|---:|---:|---:|
| 0.25 | 0.263 (0.263–0.275) | 0.032 (0.031–0.035) | 8.23× |
| 0.1 | 2.823 (2.808–2.901) | 0.207 (0.204–0.233) | 13.62× |
| 0.05 | 20.439 (20.307–20.546) | 1.102 (1.097–1.155) | 18.54× |
| 0.025 | 154.280 (152.902–155.228) | 7.186 (7.090–7.371) | 21.47× |

These ratios apply only to this scenario and measurement series. They do not establish a general speed advantage for arbitrary toolpaths or hardware.

## Separate phases of the optimized implementation

Medians are in ms. The JSON files contain the complete min/max results for every phase.

| Grid spacing mm | Initialization | Cutting | Statistics | Surface | PPM + OBJ export |
|---:|---:|---:|---:|---:|---:|
| 0.25 | 0.002 | 0.032 | 0.003 | 0.538 | 0.989 |
| 0.1 | 0.012 | 0.207 | 0.051 | 7.491 | 5.628 |
| 0.05 | 0.067 | 1.102 | 0.393 | 15.233 | 20.041 |
| 0.025 | 0.477 | 7.186 | 3.107 | 79.688 | 80.127 |

Surface generation and export dominate the 25 µm run. This favors future incremental surface updates or more efficient mesh serialization before adding SIMD or CPU workers to cutting. The baseline was measured before such extensions; they are not implemented here.

## Memory

The grid and mesh figures below are captured from actual allocated buffer lengths and capacities in the running program. They are **not process RSS estimates**. Allocator page rounding, stack, code, runtime, and image buffers are excluded. Units are bytes, not MiB.

| Grid spacing mm | Logical initial voxels | Descriptors | Pool capacity | Total grid | Mesh capacity | Currently mixed blocks |
|---:|---:|---:|---:|---:|---:|---:|
| 0.25 | 768,000 | 6,000 | 1,280 | 7,280 | 76,560 | 20 |
| 0.1 | 12,000,000 | 98,800 | 32,512 | 131,312 | 388,224 | 508 |
| 0.05 | 96,000,000 | 750,000 | 26,880 | 776,880 | 1,966,128 | 420 |
| 0.025 | 768,000,000 | 6,000,000 | 128,000 | 6,128,000 | 6,636,048 | 2,000 |

A separate 25 µm demo process exporting PPM, OBJ, and JSON reached **19,349,504 bytes peak RSS**, recorded with both `getrusage` and `/usr/bin/time -l`, and **18,776,448 bytes peak memory footprint** according to macOS. Wall-clock time was **0.17 s**, a single run rather than a median. See [`demo-0.025-time.txt`](../benchmarks/demo-0.025-time.txt) and [`demo-0.025.json`](../benchmarks/demo-0.025.json). RSS in benchmark reports is the process high-water mark, including earlier validation and warm-ups, rather than an isolated memory measurement for one repetition.

The 25 µm surface contains **112,024 quads / 224,048 triangles**. In a completed snapshot run, the separate viewer loaded and constructed this OBJ in **0.874 s**. This is a single loading measurement including scene construction, **not rendering time or an FPS measurement**. The PNG snapshot was generated and visually inspected. Viewer RAM usage and interactive frame rates were not measured.

## Volume accuracy

Analytical volume: `(2 r L + π r²) × depth = (2 × 3 × 20 + π × 9) × 4 = 593.0973355292325 mm³`. Numerical volume: removed voxels × h³. Signed error is voxelized removal minus analytical removal.

| Grid spacing mm | Remaining occupied voxels | Removed mm³ | Error mm³ | Relative error % |
|---:|---:|---:|---:|---:|
| 0.25 | 730,112 | 592.000000 | -1.097335529 | -0.185018 |
| 0.1 | 11,406,880 | 593.120000 | +0.022664471 | +0.003821 |
| 0.05 | 91,255,680 | 593.040000 | -0.057335529 | -0.009667 |
| 0.025 | 730,040,960 | 593.110000 | +0.012664471 | +0.002135 |

Errors change sign and convergence is **not monotonic**: 0.05 mm has a larger absolute error here than 0.1 mm. These results have not been adjusted or omitted. Small volume error does not bound local surface error. The 25 µm value is grid spacing, not guaranteed geometric accuracy.

## Reproduction and validation

```sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
./scripts/benchmark-all.sh
python3 scripts/validate-exports.py out/bench-0.025
./zig build -Doptimize=ReleaseFast
/usr/bin/time -l zig-out/bin/menkh demo --voxel 0.025 --out out/demo-0.025
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/demo-0.025/surface.obj --snapshot out/demo-0.025/view.png
```

At the original core checkpoint, **11/11 test groups passed in Debug and ReleaseFast**, including 35 deterministic random scenarios with eight cuts each, a center oracle without AABB restrictions, exact reference equality, allocation-failure injection, boundary blocks, stationary/reversed/split paths, idempotence, monotonically decreasing occupancy, and surfaces. PPM files and oriented OBJ volumes were independently checked for **all four** spacings using the Python script. No global dependencies were installed.
