# Geometric cutting capabilities

Menkh is a macOS/Apple Silicon geometric stock-removal engine. It consumes geometry and motion; it does not generate toolpaths or emulate a CNC controller. The comparison category is the publicly described [ModuleWorks Cutting Simulation](https://www.moduleworks.com/software-components/simulation/) and [Simulation SDK](https://www.moduleworks.com/software-components/simulation-portfolio/simulation-sdk/). Those pages describe milling, turning, mill-turn, verification, collision reporting, and inspection. They are category references, not a compatibility specification. No ModuleWorks code, assets, file formats, or performance claims are used here.

“Validated” below means the listed local tests or runs passed. It does not imply industrial certification, exhaustive robustness, or feature parity.

| Capability | Status | Evidence and boundary |
|---|---|---|
| 65,536³ virtual world / 2³² faces in 16 GB | Unsupported, resource failure reproduced | Even a 1 mm³ stock in these worlds fails the dense descriptor limit; tiled snapshots improve sparse inspection but regress on full cubes and do not support mutation/history. [Qualification](LARGE-WORLD-QUALIFICATION.md) |
| Binary voxel material state | Implemented, validated | 8³ blocks, compact descriptors, pooled bits; disconnected pieces and enclosed cavities |
| Explicit origin and finite domain | Implemented, validated | Negative/translated coordinates, non-cubic grids, edge blocks; common workpiece coordinates |
| Cuboid, cylinder, sphere stock and primitive unions | Implemented, validated | Independent exhaustive center oracles; cylinders accept a fixed unit axis |
| Flat end mill | Implemented, validated | Finite cylinder, stationary and arbitrary straight translation at fixed orientation; analytic axial/radial time-interval intersection |
| Ball end mill | Implemented, validated | Lower hemisphere plus cylindrical cutting length, not a sphere alone; independent profile oracle; discrete convex pose search, continuous-coverage and randomized scalar comparisons |
| Bull-nose end mill | Implemented, validated | Bottom corner radius, flat central face, cylindrical flute; independent profile oracle |
| Taper and idealized drill | Implemented, restricted | Truncated cone and full conical cutter; no flutes, chisel edge, relief, or production drill definition |
| Fixed tilted orientation / 3+2 | Implemented, validated | Unit tool axis fixed within each operation; arbitrary straight translation |
| Circular/helical motion | Implemented, restricted | Arbitrary planar basis and normal rise; fixed tool axis, bounded conservative chord and pose approximation; arc shank/holder and feed inputs explicitly rejected |
| Simultaneous orientation change / 5-axis | Unsupported | Rejected, including nearly equal but distinct endpoint axes; no quaternion interpolation |
| Cutting vs shank/holder geometry | Implemented, validated | Separate finite cylindrical noncutting components, offsets above cutting length |
| Stock/fixture collisions | Implemented, restricted | Swept center contacts plus conservative whole-cell separation; explicit not-checked/unresolved states, independent fixtures, operation IDs and candidate bounds; pre-operation stock conservatism remains |
| Versioned JSON jobs | Implemented, validated | Strict Zig JSON parsing, units, tool/operation validation, stable IDs, operation history |
| Resumable state | Implemented, validated | Little-endian checked format, checksums, slot/index/padding validation; same-grid resumption |
| Reversible history | Implemented, validated | Transactional Zig replay tests; native general-job and full 4096³ forward/backward/forward replay |
| Pool compaction | Implemented, restricted | Explicit checkpoint boundary; old slot-index histories must not be applied afterward |
| Binary STL stock and target | Implemented, restricted | Shared vertical scanlines with three-direction parity fallback and conservative surface-excluded region filling; edge manifold/winding and intersection checks; rotated concave and cavity fixtures; no repair, ASCII STL, STEP, or general CAD kernel |
| Removed/remaining volume and engagement | Implemented, validated | Count × voxel volume; engagement is newly removed volume per operation |
| Feed-derived quantities | Implemented, restricted | Straight-line length/feed only when supplied; no acceleration, dwell, spindle, or machine-cycle model |
| Point, ray and arbitrary-plane sections | Implemented, validated | CPU occupancy, voxel-face ray hit, orthonormal plane PPM sampling; viewer X/Y/Z clipping |
| Defect-region inspector | Implemented, validated on macOS | Exact six-connected regions, operation-linked contact/unresolved events, filter/focus/section/seek, JSON export and deterministic saved-state regeneration; no final-defect operation attribution. [Evidence](DEFECT-INSPECTOR.md) |
| Target excess and missing material | Implemented, validated | Exact bitwise comparison on the same grid; sampled surface distances separately reported for one analytic target primitive |
| Turning | Implemented, restricted | Complete-revolution rectangular-insert envelopes for longitudinal/facing cuts, explicit spindle origin/axis; independently validated radial profiles |
| Combined milling and turning | Experimental geometric composition | Same stock and tilted/translated spindle transforms tested; no spindle-angle evolution, turret, synchronization, or production mill-turn claim |
| Final-surface exposure attribution | Implemented, restricted | Exact raster-history face IDs, operation/tool colors and picking on macOS; final frame only, initial/prehistory unknown, no rate/time heatmaps. [Evidence](SURFACE-PROVENANCE.md) |
| Direct Metal inspection | Implemented, validated | Rectangular grids/origins, history scrubbing, X/Y/Z sections, target colors, fixture and shank/holder visibility, occupied-point picking |
| General tool rendering | Restricted | Flat and complete ball cutter, shank and holder shown at recorded poses; other general cutter shapes are not yet rendered. Legacy mesh drill animation retains its tool illustration |
| Incremental GPU updates | Implemented | Changed descriptors/bits uploaded in shared buffers; CPU waits for prior GPU command; no whole-state upload each frame |
| Surface export | Implemented, validated | Greedy voxel-boundary OBJ quads, outward orientation, independently checked oriented volume and unit-edge closure; nonmanifold contacts reported |
| Surface reconstruction / subvoxel truth | Unsupported | No Hermite samples, SDF material grid, resampling, or geometric smoothing. Normal averaging affects lighting only |
| Sparse top level | Measured inspection prototype | Immutable two-level tile snapshot with occupancy queries; mutable engine remains dense, comparison includes sparse and full 4096³ scenes |
| CPU SIMD cutting | Implemented, restricted | f64 XY masks shared across Z blocks for constant-Z or pure vertical +Z flat sweeps; scalar fallback and voxel-exact differential tests. [Measurements](CPU-PERFORMANCE.md) |
| CPU workers / GPU cutting | Unsupported in material updates | One deterministic cutting worker; eight-worker read-only predicate benchmark is diagnostic only |
| Kinematics, controller, thermal/force simulation | Outside product boundary | No collision against moving machine components, G-code execution, feeds/speeds planning, or physical cutting forces |

The immediate product gaps are external production-part qualification, actionable local 3D metrology/clearance, and a stable integration/resource contract. Broader orientation-changing sweeps and production mill-turn remain separate capability gaps; see the [product roadmap](PRODUCT-ROADMAP.md). The viewer is evidence of inspectability, not evidence of feature parity.

## Formal verification

Implemented and locally validated: 34 named Lean results including history/pool contracts, axiom audits, and 20,480 Lean/Zig differential records. Restricted to the explicit models and hypotheses in [FORMAL-VERIFICATION.md](FORMAL-VERIFICATION.md). Full Zig refinement, floating-point correctness and certified geometric clearance remain unsupported.

Windows x86-64 CLI/benchmark: experimental, cross-compiled locally; native runtime
checks are in the Windows CI job. Zig 0.15.2 builds it; MSVC integration of the engine is unsupported. See [Windows instructions](WINDOWS.md).
A separate [Windows D3D12 viewer](../viewer/windows/README.md) implements native
voxel playback, orbit/pan/zoom, scrubbing and Z sections. Flat tools/shank/holder
are visualized; targets, fixtures and non-flat cutter display are restricted as
documented. Windows CI renders via WARP; hardware interaction/FPS are unmeasured.
Checkpoint surface inspection counts six-neighbor boundary voxels and exposed
faces independently of mesh generation; see [count semantics](INSPECTION-COUNTS.md).

The [imported finishing milestone](FINISHING-RESULTS.md) records a frozen long-job
experiment, independent sampled contour evidence and checkpoint/replay results.
Its input triangulation and toolpath allowance/scallops are separate from simulation error.

[Scanline import validation](SCANLINE-IMPORT.md) originally accepted 13 transformed
fixtures and recorded three rejections. The [shared-topology fix](MILLING-ROBUSTNESS.md)
now accepts all 16 with exact scalar and independent oracle comparisons. Genuine
foldovers and crossings remain rejected.
