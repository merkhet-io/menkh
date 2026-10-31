# Inspecting a calculation in progress

On macOS and Windows, `menkh-viewer job.json --live` opens consistent completed-operation
material windows while the engine continues cutting. The existing standalone
history viewer and final archive are unchanged.

```sh
./scripts/live-demo.sh
# Existing job; choose a fresh output directory:
zig-out/bin/menkh-viewer examples/general.json --live --job-output out/my-live-run
```

The demo generates 2,501 continuous ball-end segments over a 24 × 18 × 8 mm
stock at 0.025 mm voxel spacing (960 × 720 × 320 cells). It is a geometric
inspection workload, not a feed-timed machining program. The path generator,
including its 0.005 mm motion tolerance, is `scripts/live-demo.py`.

- **Follow latest** replaces the displayed window at most twice per second.
  Uncheck it before scrubbing or playing the retained window. Camera and section
  settings survive updates. The title gives the global completed-operation range;
  the slider is relative to that window.
- **Pause calculation** requests a stop at the next operation boundary. The status
  acknowledges the operation where the engine actually paused. Resume continues
  from the same material state. Holding inspection and pausing calculation are
  separate actions.
- **Cancel** in live mode is cooperative, including during pause. A long operation
  must finish before cancellation is observed. Logs and the last consistent live
  window remain available; they are not a completed result.
- Successful calculation opens the normal full-history result, with its usual
  target, fixture, defect and provenance inspection options.

## Publication contract

The optional job member enables publication for the CLI and whole-job C API too:

```json
"live_inspection": {
  "start_paused": false,
  "history_operations": 32,
  "publish_every_operations": 8,
  "min_publish_ms": 100,
  "max_snapshot_bytes": 134217728
}
```

Those are the defaults. History is limited to 1–256 operations, publication
stride to 1–history_operations, minimum interval to 0–60,000 ms, and payload
budget to 4 KiB–1 GiB. Invalid settings fail before stock initialization.
`--live` in either native viewer preserves an existing configuration or supplies
these defaults in a separate launch-job copy; it never rewrites the source job.
Relative input resources still resolve against the original job directory.

The engine copies a base material state and publishes its completed deltas in
one of three reusable `live/slot-N` directories. A window contains at most the
configured number of operations. This is a succession of bounded chunks, not a
promise to retain the last N operations at every instant: the range resets at a
chunk boundary, and can shorten further to satisfy the payload budget. The
manifest records `first_operation`, `completed_operations`, `total_operations`
and `live_sequence`. Material and retained deltas are exact, without decimation.

Readers must follow this protocol, including when opening files after a run:

1. Read `live/latest.json`, version 1, to select slot and sequence.
2. Acquire a nonblocking shared lock on the stable `live/slot-N.lock` file.
3. Read that slot's `voxel-animation.json` and verify `live_sequence` matches.
   On contention or mismatch, release and retry later.
4. Hold the lock for the **entire** lifetime of the history reader. Seeking reads
   delta files lazily. Never use a raw live slot as an ordinary unleased viewer
   input while its producer can still run.

POSIX readers use `flock`; Windows readers lock byte 0, length 1 (the same range
as Zig's file locks). The producer obtains an exclusive lock before replacing a
slot, never rewrites the latest published slot, and atomically renames the latest
pointer only after writing all its files. Locks survive directory rotation because
the lock files are outside those directories. A reader verifies the sequence after
locking to handle a stale pointer safely. No partially written material is exposed.
Use a local filesystem with working advisory locks and atomic renames; network
filesystems and distributed readers are not qualified.

If all reusable slots are leased, the engine skips publication and continues.
There is no growing queue and no wait for rendering. `skipped_publications`
reports that backpressure. A crashed reader releases its OS locks automatically.
A fresh output `live` directory is required; an earlier run's channel is never
silently reused underneath a surviving reader.

## Controls, bounds and failures

Create `live/pause` to request pause; remove it to resume. Create `live/cancel` to
cancel, including a paused job. `live/status.json` acknowledges pause/resume and
reports completion, cancellation or failure. While paused, C progress callbacks
remain cancellable at the same completed-operation boundary (phase 6 before the
first cut, phase 3 afterwards); repeated callback counts are intentional.
Initial setup failure can precede creation of a status file. Abrupt process death
cannot write a terminal status: clients must also observe their worker/process.

The live channel retains at most three payloads, each bounded by
`max_snapshot_bytes`, plus small lock/control files. The budget includes base
blocks, base pool, deltas and manifest. If the base or manifest cannot fit, the
operation fails explicitly with `LiveSnapshotTooLarge`; no geometry is truncated.
Failed publication can leave an unpublished partial slot; the last published
window remains valid. Writes use filesystem caching, not a durable-storage commit.

Producer RAM adds one copied base grid, JSON encoding and file-copy scratch.
`base_capacity_bytes` reports the allocated base buffers. Pool growth can briefly
hold old and replacement allocations. The budget does not bound the engine's
existing mutable grid, input JSON, operation reports or cutting scratch.
The **full archival history on disk is still retained separately** and grows with
the job. Live retention does not claim to solve archival-history storage growth.

The viewer retains one leased renderer, with an old and new renderer briefly
coexisting during handover. It rebuilds the material buffers between publications;
within a retained window, the existing changed-block replay is used. There is no
claim of incremental cross-publication uploads. `live-viewer.jsonl` records load/
upload time, seek time, material-buffer bytes and process peak RSS. `report.json`
records publication counts, skips, producer publication time (`write_ns`, including
rebasing and bookkeeping), base capacities, peak payload, archival history and
cutting scratch separately. RSS and allocated buffer counts are different metrics.

## Validation and limits

```sh
./zig build test
./zig build test -Doptimize=ReleaseFast
./zig build -Doptimize=ReleaseFast
python3 scripts/test-live-inspection.py
python3 scripts/live-demo.py
python3 scripts/benchmark-live.py --out out/live-benchmark-new
```

The transport regression independently decodes occupancy from published windows
and the completed archive, checks chunk rebasing, pins all three slots, tests
pause/cancel and an injected write failure, and compares final state bytes with
publication disabled. Unit tests inject allocator failures. macOS and Windows CI
run the transport regression; a Metal device is not required there.

Both native viewers support live exposure colors, target comparison, fixtures,
sections and occupied-material picking. Windows non-flat cutter visualization
remains unsupported. Live reports retain per-operation contacts; connected defect
regions remain completed-result data. See the [overlay contract](LIVE-OVERLAYS.md)
for global IDs across rebases, immutable assets, controls and explicit limits.

File publication, locking, the native viewer and this transport test are outside
the Lean model. Existing proofs and bridge tests were rerun; no additional formal
verification claim is made. See [measured evidence](evidence/live-inspection/README.md).

## Windows live viewer

```powershell
.\out\windows-viewer\menkh-viewer.exe examples/pocket-25um.json --live --job-output out/windows-live-pocket
# Explicit subprocess mode instead of the adjacent DLL:
.\out\windows-viewer\menkh-viewer.exe examples/pocket-25um.json --live --engine zig-out/bin/menkh.exe --job-output out/windows-live-cli
```

The progress window has **Pause calculation / Resume calculation**, **Follow latest**
and **Cancel**. Scrubbing, Home/End, arrow keys or playback automatically uncheck
Follow latest so an incoming publication cannot discard the inspected state.
Recheck it to catch up. Closing the live material window hides it; toggling Follow
latest off/on shows it again. Closing the calculation window requests cancellation.
After cancellation or failure, interactive mode retains the last leased window
until it is closed. Successful calculation opens the full ordinary history.

The runner keeps relative resources rooted at the original job directory (or the
explicit `--working-dir`). It creates a temporary live-enabled launch copy for the
engine and retains that copy as `live-job.json` after the worker exits. The original
job is unchanged. Live DLL cancellation polls the callback even while paused;
subprocess cancellation uses the channel's control file. No simulation state is
read directly from the DLL worker.

`live-viewer.jsonl` separates history loading/seeking, D3D12 renderer setup, material
upload (CPU copy plus GPU transfer and fence wait), and attachment/first rendering.
It reports CPU material/history/dirty-buffer capacities, explicit D3D12 resource
allocation sizes and process peak working set. D3D12 allocation figures exclude
swapchain buffers and driver overhead; process RSS is not dedicated GPU memory.
DLL mode includes engine and viewer in the same process, whereas subprocess mode
reports viewer RSS separately from the engine's report. Both modes reload material
buffers at publication boundaries; within a window, seeking uses changed-block
updates. Renderer and buffers can coexist briefly during handover.
Compiled shader bytecode is cached for the process; restart the viewer after
editing `Voxel.hlsl`. Device/pipeline creation and full material uploads still
occur at publication boundaries, and the first view includes shader compilation.

Use `--live-evidence DIR --warp --debug --run-only` for automated validation with
CPU-state dumps and real D3D12 images. It verifies each observed window's history
and exact rendered rewind, so its load/seek and RSS measurements include extra
verification work. WARP is software rendering, not hardware-GPU FPS evidence.
The Windows CI script `scripts/test-windows-live.py` drives actual controls for both
DLL and subprocess runs and compares every observed material state with an
independently decoded CLI archive. It exercises held-reader backpressure,
pause/resume, keyboard seeking, cancellation and an injected history-write failure.
See the [Windows native validation and measurements](evidence/windows-live/README.md)
for the actual 25 µm run, screenshots and remaining UI latency limitations.
