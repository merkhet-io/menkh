# General-engine validation and measured results

Measured October 30, 2026 on Apple M5 Max, 18 CPU cores, 128 GiB RAM, macOS 27.0.1, native aarch64-macos, Zig 0.15.2. Performance builds use ReleaseFast and one CPU worker. No global packages were installed. Source fingerprints and environment details are recorded in [environment.json](../benchmarks/engine/environment.json). The starting checkout was `5c9e77a0351ae85c697318b2e942a9a00988c913`.

## Baseline and regression checks

Before implementation, the original 17 tests passed in both Debug and ReleaseFast. The 25 µm groove reproduced 730,040,960 remaining voxels, 112,024 surface quads, a 7.332 ms single cut and 6,128,000 allocated grid bytes. The full 4096³ drill reproduced 2,159,116,288 initial and 1,333,399,870 final occupied voxels in 3.198 s, with 647,528,448 bytes peak RSS. These are single baseline runs, not medians; raw records are [groove](../benchmarks/engine/baseline-groove.json) and [drill](../benchmarks/engine/baseline-drill.json). The sandbox blocked `/usr/bin/time`'s extra sysctl query; internal monotonic timers and `getrusage` values were successfully recorded.

The current suite passes **35/35 test groups in both Debug and ReleaseFast**, including the 17 original groups. Logs: [Debug](../benchmarks/engine/debug-tests.txt), [ReleaseFast](../benchmarks/engine/release-tests.txt).

Added coverage includes primitive unions and nonzero origins; fixed tilted, reversed, split and short cylinder sweeps; independent dense time samples; independent ball/bull/taper/cone profiles; continuous helical boundary samples; longitudinal/facing radial oracles; milling plus a translated tilted turning spindle; cavity/disconnected geometry; small dimensions and large local offsets; malformed parameters; allocation-failure injection; checkpoint corruption, compaction and exact replay; STL boundary/parity/open/intersecting geometry; and tile/dense occupancy equality. Only one worker exists, so cross-worker determinism is not claimed.

CLI integration verifies uninterrupted versus resumed jobs, resumed compacted checkpoints, rejection of six invalid-input cases, positive noncutting stock/fixture collision reports, and oriented mesh boundary closure. See [integration.json](../benchmarks/engine/integration.json). Native playback separately verifies byte-exact initial descriptors and original pool bytes after backward replay, then equal final occupancy after replay, on [general jobs](../benchmarks/engine/replay-general.json) and [the full 4096³ dataset](../benchmarks/engine/replay-4096.json).

The original 225-state mesh drill still ends at 267,344 voxels; the reproduced generation took 1.93 s in one run. The original 25 µm groove still yields 730,040,960 voxels and its independent PPM/OBJ check passes. All four original benchmark spacings were rerun and their exports independently validated. Their updated raw records are in the same benchmark directory; the original historical tables remain unchanged.

## Varied job suite

One complete warm-up followed by three measured repetitions for each implementation, each in a fresh process with identical initial stock. Scalar runs precede optimized runs. Both use the same export/inspection settings and declared approximate-motion semantics. Every result is consumed: all repetitions are compared voxel by voxel, and every exported mesh's oriented volume is compared to the count-derived volume. Greedy-quad edges are subdivided into unit lattice edges to check closure despite T-junctions; nonmanifold contacts are counted separately. Imported fixtures include rotated concavity and a closed internal cavity.

Times below are total cutting time across the scenario's operations, in milliseconds. Surface generation, export, statistics, history writes, and collision queries are separate. Stock-input timing further separates file reads, STL parsing/BVH construction, voxelization and state decoding. Full samples, phase timings, memory high-water marks, history sizes and source hashes are in [suite.json](../benchmarks/engine/suite.json).

| Scenario | Scalar median ms | Optimized median ms (min–max) | Allocated grid bytes | History bytes |
|---|---:|---:|---:|---:|
| groove | 0.245 | 0.066 (0.066–0.066) | 1,280 | 1,216 |
| ball-finishing | 66.123 | 17.395 (17.360–19.568) | 2,304 | 6,680 |
| deep-thin-wall | 1.368 | 1.072 (1.058–1.135) | 4,352 | 17,536 |
| tilted | 0.330 | 0.231 (0.229–0.232) | 2,816 | 2,660 |
| long-overlap | 70.842 | 10.858 (9.290–10.893) | 1,280 | 1,216 |
| sparse-world | 0.020 | 0.021 (0.019–0.029) | 32,576 | 560 |
| imported-cavity | 0.000 | 0.000 (0.000–0.000) | 832 | 0 |
| imported-concave-rotated | 0.000 | 0.000 (0.000–0.000) | 832 | 0 |
| turning-envelope | 0.214 | 0.215 (0.214–0.220) | 3,328 | 4,416 |
| helix | 77.684 | 51.969 (44.497–53.195) | 2,560 | 2,736 |

Imported-stock cases have zero cutting time by design; their import/voxelization and export phases are recorded. The long-overlap scenario applies 200 operations. The standard varied jobs use 250 µm spacing, except the sparse-world case at 500 µm. This is a varied correctness/performance baseline, not an industrial workload-size claim. There is no CPU affinity, thermal isolation or guaranteed clock rate. Writes are cached and do not call `fsync`; this does not measure durable SSD throughput.

## Full 4096³ regression

One warm-up and three fresh measured processes, preserving the original drill geometry and endpoint count:

- Initialization: **140.526 ms median**, 127.633–145.766 ms.
- All cuts including reservation: **4369.116 ms median**, 4049.009–4738.279 ms.
- Complete generation: **4799.664 ms median**, 4449.267–5185.602 ms.
- Peak process RSS: **647,610,368 bytes**; final bitfield capacity: **51,714,560 bytes**.

The general implementation is **slower than the original specialized drill path** (original checkpoint's repeated median was 3.160 s). This regression is retained explicitly rather than hidden behind a faster small example. The material counts, pool size and replay correctness are preserved. Generic classification/history bookkeeping remains an optimization target. Phase timing motivated radial-column reuse and occupied-bit skipping; no SIMD, thread, or GPU-cutting speedup is claimed. The separate original constant-Z groove remains around 7 ms at 25 µm.

Raw [summary](../benchmarks/engine/drill-summary.json), [warm-up](../benchmarks/engine/drill-run-0.json), and three measured runs (`drill-run-1.json` through `drill-run-3.json`) are versioned.

## Coarse tile experiment

A dense coarse directory points to allocated 8³-block tiles; empty tiles have no descriptor slab. It is an **immutable inspection snapshot**, not the mutable engine or history format. Comparison used both the sparse 4096³ cylinder and a completely occupied 4096³ cube. One warm-up plus four measured repetitions per scene; each queries the same one million deterministic random positions and validates the hit count. Query times include equal random-number generation overhead. Conversion time and simultaneous dense-plus-snapshot process RSS are in [tiles.json](../benchmarks/engine/tiles.json).

| Scene | Dense allocated bytes | Tiled allocated bytes | Dense query median ms | Tiled query median ms | Snapshot conversion median ms |
|---|---:|---:|---:|---:|---:|
| sparse-cylinder-4096 | 550,143,104 | 33,423,360 | 12.495 | 6.781 | 199.234 |
| full-cube-4096 | 536,870,912 | 537,919,488 | 11.764 | 21.278 | 924.536 |

Sparse snapshots substantially reduce empty-space memory, while full occupancy adds directory overhead and worsens random-query locality. These measurements do not justify replacing every mutable grid with this layout. Mutation/history integration remains a significant gap. Pool compaction is available at checkpoint boundaries; it is not used to invalidate live histories.

## Non-grid-aligned accuracy experiment

Sphere radius 1.43 mm centered at (2.13, 2.07, 2.19) inside a 4.5 mm cube. Analytical volume is 12.248889638367794 mm³. The exported mesh's oriented volume is checked independently. Deviations below sample mesh vertices against the analytic sphere; they are **sampled estimates**, not a general maximum-error guarantee. Error includes center occupancy and voxel-face reconstruction, but no motion approximation because this fixture is stock-only.

| Spacing mm | Occupied voxels | Volume error mm³ | Largest sampled vertex deviation mm |
|---:|---:|---:|---:|
| 0.25 | 782 | -0.030139638 | 0.206429039 |
| 0.1 | 12,246 | -0.002889638 | 0.084674761 |
| 0.05 | 98,007 | +0.001985362 | 0.043058044 |
| 0.025 | 784,047 | +0.001844737 | 0.021602563 |

No monotone convergence is imposed. These samples are consistent with the fixture-specific one-sided half-cell-diagonal argument in [ENGINE.md](ENGINE.md); they do not establish two-sided geometric accuracy or preservation of subvoxel walls and holes. Motion error bounds are reported separately for cutting jobs. Floating-point and STL input errors are not folded into a misleading “25 µm accuracy” claim.

## Native inspection

The viewer was built and actually rendered the general scene with a translated origin, rectangular grid, clipping, target excess/missing colors, fixtures and noncutting tool components. It also rendered the original 25 µm OBJ. [General GPU measurements](../benchmarks/engine/render-general.json) and [4096³ GPU measurements](../benchmarks/engine/render-4096.json) use three warm-ups and ten offscreen samples at 1280 × 900 with four rays per pixel. They record **GPU command duration only**, not interactive FPS, CPU history upload time, display VSync or machining time. Camera framing and enabled layers differ from the original viewer benchmark, so those render times are not a controlled speed comparison. Manual interaction and end-to-end interactive frame rates are not benchmarked.

## Reproduce

```sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
./zig build -Doptimize=ReleaseFast
./scripts/general-demo.sh
python3 scripts/validate-engine.py
python3 scripts/benchmark-engine.py --repeats 3
./scripts/benchmark-all.sh
./scripts/benchmark-4096.sh
zig-out/bin/menkh tiles-bench out/tiles-bench
zig-out/bin/menkh job examples/turning-envelope.json --out out/turning
zig-out/bin/menkh job examples/helix.json --out out/helix
zig-out/bin/menkh-viewer out/general/voxel-animation.json --verify-history out/general/replay.json
```

The native viewer requires a macOS graphical session. CLI building and simulation do not require building or launching it. No merge, deployment or remote publication is part of this milestone.
