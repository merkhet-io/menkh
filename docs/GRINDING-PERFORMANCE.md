# Grinding performance and comparable inspection

The screw protocol in [SCREW-GRINDING.md](SCREW-GRINDING.md) remains unchanged:
1,024 continuous XYZAC segments, 0.01 mm motion tolerance, two starts, 12 × 40 mm
stock. Spacing and display settings must accompany any screenshot or video.
The earlier macOS video used 0.025 mm and averaged lighting normals. A Windows
screenshot at 0.1 mm with face normals is neither the same geometry nor the same
lighting. Smoothing changes lighting only; it cannot restore missing detail.

## Windows phase report

No rerun or Python installation is needed to examine an existing calculation:

```powershell
.\scripts\summarize-grinding.ps1 out/screw/result/report.json
```

Send its JSON together with the CPU model, `git rev-parse HEAD`, and the original
command. The report separates cutting, delta-file writes, collision checks and
remaining phases. It excludes viewer loading/rendering. Cached writes are not
measurements of durable storage. On the existing Mac 25 µm run, cutting took
434.354 s and all per-operation history writes together took 0.343 s. This does
not establish Windows filesystem overhead; collect that report separately.

## Kernel changes

Profile distances evaluate eight X coordinates together with f64 arithmetic.
Sparse rows use the scalar predicate. Tests compare signed distances bit for bit
and compare masks against exhaustive scalar pose evaluation. The declared motion
bound, sampled poses, tool profile and voxel-center convention are unchanged.
Counters include executed inactive SIMD lanes, so point-pose counts must not be
interpreted as useful occupied-voxel throughput or compared directly with Jens.

Temporal rejection envelopes are prepared once per operation rather than once
per visited block. Optional CPU workers calculate masks for disjoint partial
blocks against the immutable pre-operation state. After they join, a serial
pass updates material, assigns pool slots and writes deltas in original order.
This preserves descriptor, pool and history bytes across worker counts.

All allocations and thread creation precede mutation. If spawning fails,
started workers join before the error is returned; no material is changed.
Scratch capacity is reported, reused across operations and released with Changes.
Threads use 1 MiB stacks; process RSS includes resident stack pages. The current
implementation creates threads per eligible operation. It is not a persistent
worker pool. At least 32 partial blocks per worker are required; exact flat XY
and reference paths remain serial. Requested workers are a maximum, 1–64;
`operations[].work.workers_used` records the actual count. Default remains one.

```powershell
.\zig.ps1 build -Doptimize=ReleaseFast
.\zig-out\bin\menkh.exe grinding-demo --voxel 0.1 --workers 8 --out out/screw-w8
.\viewer\windows\build.bat
.\out\windows-viewer\menkh-viewer.exe out/screw-w8/result/voxel-animation.json
```

Use a new output directory. For arbitrary jobs, set optional JSON `workers`.
The scalar reference always uses one worker. Different operations still execute
in order: this change does not batch an entire toolpath or introduce dexels.

## Reproduction and limits

```sh
python3 scripts/benchmark-screw.py --baseline /path/to/previous-menkh --workers 8 --out out/screw-w8-comparison
```

One warm-up plus three repetitions, alternating engine order, identical geometry
and outputs. The optimized JSON differs only in its explicit worker request;
both job hashes and binary hashes are recorded. Final encoded states must match.
Do not mix these results with older measurements from another session.

The native viewers now intersect the recorded piecewise-conical profile wheel
for display, including its two external caps. This is an idealized cutting
portion, not a model of abrasive grains or a complete grinding machine.
Independent Metal ray tests cover caps, tapered sides, waists, tangency, inside
origins, transforms and scaling. D3D12 runtime validation requires Windows CI.

These SIMD, culling, threading and viewer algorithms are outside the Lean model.
The existing model proofs do not prove this executable or its performance.

## Windows lighting option

For recorded playback, add `--smooth-lighting` or press **L** to toggle averaged
occupancy normals. The status line explicitly says “smoothed lighting only”.
This uses the same five-cell neighborhood as macOS. Ray intersections, voxel
silhouettes, picking, exposure IDs and material metrics remain unchanged. It
adds up to 125 occupancy reads per visible stock sample and is opt-in; no FPS
improvement is claimed. Windows CI compares raw/smoothed background silhouettes
and checks that the recorded wheel changes the rendered image. Target and
fixture overlays retain face normals.

The [measured evidence](evidence/grinding-workers/README.md) includes matching
100/25 µm screenshots with normal smoothing disabled on both.
