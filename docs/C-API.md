# C embedding API and native viewer integration

The version-1 C ABI supports both individual material operations and complete
JSON jobs. The Windows viewer can load the same DLL as the independent C host;
no simulation subprocess is needed for this mode. macOS keeps its existing
process-based viewer runner; its C hosts support both library forms.

```sh
./zig build sdk -Doptimize=ReleaseFast
./zig build sdk-static -Doptimize=ReleaseFast
./zig build sdk-test
./zig build sdk-test -Doptimize=ReleaseFast
python3 scripts/test-sdk.py
```

The shared target installs `include/menkh.h` and a dylib or DLL/import library.
The static target installs `libmenkh-static.a` or `menkh-static.lib`. The macOS
static target uses the installed Apple librarian to normalize Mach-O archive
alignment and includes the Zig runtime helpers needed by an ordinary C linker.
No global packages are installed. Normal CLI builds remain independent.

## Ownership, concurrency and compatibility

- `menkh_abi_version()` returns 1. Existing `_v1` entry-point layouts remain fixed;
  the job/history entry points are additive. Hosts must check their required
  symbols as well as the ABI version. No C++ ABI is exposed.
- Opaque material handles own grid and scratch allocations. Destroy them with
  this library, not the host allocator. Inputs and caller-owned output buffers
  are never retained. The public constructor selects the platform C allocator;
  custom allocator callbacks are not exposed.
- Serialize calls on a material handle. Different handles/jobs may be independent
  provided they use distinct output directories. There is no global mutable
  error buffer and the job API never changes process working directory.
- Callbacks run synchronously on the thread calling `menkh_run_job_v1`; they must
  not unwind across C. Context ownership stays with the caller until return.
  Immutable status-message strings belong to the library.
- Buffers/pointers supplied by the host must be valid and live for the call.
  Null arguments and capacities are checked. State size queries return required
  bytes without writing an undersized buffer. Constructors clear their output
  handle on failure; failed cuts preserve occupancy (scratch capacity may grow).
- State buffers use the existing checksummed `MENKHST1` format, capped at 1 GiB
  on read. This is compatible with CLI checkpoints. History uses the existing
  validated delta format; do not apply deltas across compaction/unrelated states.

## Material operations and copied history

Create cuboid stock or restore checked state bytes. Apply complete flat/ball tools
along fixed-axis lines, or cylindrical wheels under the [XYZAC contract](GRINDING.md).
Query occupancy/counts and receive removed volume, remaining cells and declared
motion bounds. Geometry remains voxel-center occupancy, not a physical time model.

`menkh_history_write_v1` copies the last successful cut's delta into caller storage.
Copy it before the next cut. `menkh_history_apply_v1` validates then applies it
forward/backward transactionally, refreshes counts and invalidates the last-delta
view. The host controls retained history size; the library does not retain all
past deltas automatically. Checkpoint/resume and replay are distinct operations.

## Whole jobs, progress and cancellation

`menkh_run_job_v1(job, output, working_dir, callback, context)` executes the same
versioned JSON job implementation as the CLI, including its supported stock,
target, fixture, tool, motion, query and export features. Paths passed to the API
must be absolute UTF-8. Relative asset paths resolve against `working_dir` without
calling `chdir`. Output must be new/empty; the viewer's `launch.json` is allowed.
Existing material/history output is rejected rather than overwritten.

The optional callback receives phase, completed-operation count and total:
0 stock, 1 target, 2 fixtures, 3 completed cut, 4 finalizing, 5 complete, 6 ready.
An initial notification precedes parsing and has total zero. Return nonzero to
request cancellation. Requests are observed at these consistent boundaries;
there is no promise to interrupt a long cut or import midway. Cancellation
retains completed deltas/partial files, returns `MENKH_CANCELLED`, and does not
publish a final result manifest. After phase 5, cancellation cannot roll back the
completed job and its return value is ignored. Failures have stable status codes
and a best-effort per-run diagnostic log.

Progress is not live material inspection. The whole-job API publishes completed
results; #24 separately tracks bounded live snapshots and retained-range seeking.

## Windows viewer

Place `menkh.dll` beside `menkh-viewer.exe` and open a job; the viewer selects the
library automatically. Batch/project builds copy an available repository-built
DLL, and portable packages include it. `--library PATH` selects one explicitly;
`--engine PATH` explicitly retains the subprocess path. These flags are mutually
exclusive. Missing or incompatible selected libraries fail clearly.

A worker thread invokes the job API, the UI pumps messages and shows progress,
and Cancel/close requests cancellation after the current operation. The worker
is joined before unloading the DLL or destroying its callback context. Only a
successful job opens the final renderer. `launch.json` identifies library mode
and the viewer PID; no engine process is created.

## Validation

`examples/embed.c` is compiled independently against shared **and static** builds.
It checks 12,000 occupancy queries against its own capsule-groove calculation,
idempotence, invalid inputs, buffer bounds, dense-grid capacity rejection,
corrupt states, copied-history undo/redo, and byte-identical resumed rotary cuts.
The CLI reads the resulting checkpoint. Failure injection covers allocation and
failed-cut atomicity in Debug and ReleaseFast.

`examples/run_job.c` exercises the callback from a C host. Tests require exact
material equality with CLI jobs, relative Unicode/spaced asset paths, unchanged
process working directory, overwrite refusal, invalid jobs, and cancellation
before work and after operations 1 and 3. Windows CI runs the same viewer lifecycle
suite against both process and DLL modes, including cancellation with no surviving
worker/process, errors and automatic D3D12 result rendering. These tests do not
prove the complete ABI or Zig executable; the existing Lean scope is unchanged.
