# Synchronous C embedding increment

Issue #23 remains open: this is a working, deliberately small embedding boundary,
not the complete SDK integration contract or a replacement of the viewers' job
runner. The viewers still use a supervised CLI process.

```sh
./zig build sdk -Doptimize=ReleaseFast
./zig build sdk-test
./zig build sdk-test -Doptimize=ReleaseFast
python3 scripts/test-sdk.py
```

The optional `sdk` target installs `include/menkh.h` and a shared library under
`zig-out` (dylib on macOS, DLL/import library on Windows). Ordinary CLI/viewer
builds do not require it. `examples/embed.c` is an independent C11 host: it creates
stock, cuts, queries all cells against its own oracle, serializes/restores state,
and cuts both the uninterrupted and resumed handles. It writes a normal
`MENKHST1` checkpoint that the existing CLI can inspect.

## Implemented contract

- `menkh_abi_version()` returns 1. Function names have a `_v1` suffix and layouts
  are fixed in the header; incompatible extensions must use new entry points.
- Opaque handles own their grids/scratch and must be destroyed using this library.
  Inputs and caller-owned output buffers are not retained. Do not free a handle
  with the host's allocator. Internally each handle carries its allocator; this
  C entry point currently chooses the platform C allocator. Custom allocator
  callbacks are not exposed yet.
- Calls on one handle must be serialized; separate handles are independent.
  There is no shared mutable error buffer. Status messages are immutable strings
  owned by the library; callers must not free them.
- Create cuboid stock, or load existing checksummed material-state bytes. The
  reader accepts at most 1 GiB. No JSON/STL parsing entry point is exposed yet.
- Apply complete finite flat or ball-end tools along fixed-axis lines; cylindrical
  wheels additionally accept the [bounded XYZAC contract](GRINDING.md).
- Point occupancy, cached occupied count, removed/remaining counts, raster volume,
  motion bound, and wheel sweep-piece count are returned by real operations.
- A failed cut leaves material unchanged; allocated scratch capacity may grow.
  Reports are written only on success. Constructors/restorers clear the output
  handle before attempting work. Null pointer arguments are checked; as with
  ordinary C APIs, non-null pointers and supplied capacities must refer to valid
  live objects/buffers of the stated size.
- State size query returns `MENKH_BUFFER_TOO_SMALL` with the required byte count.
  Insufficient buffers are not written. Output uses the existing portable state
  format; loading validates it rather than trusting caller metadata.

The host drives one synchronous operation at a time and can report progress or
cancel **between calls**. Mid-operation cancellation, job-level callbacks,
borrowed views into occupancy/history, history replay, fixture/holder checks,
mesh import, and native viewer integration are not part of this API yet. Nothing
silently substitutes those behaviors. Material is still authoritative binary
occupancy; these calls do not supply physical machining time.

## Validation

The independent C host checks all 12,000 voxel centers of a capsule-groove case,
zero-error exact-cylinder reporting, idempotence, rejected orientation changes,
invalid queries, undersized output buffers, corrupt checkpoint rejection and
byte-identical uninterrupted/resumed rotary cutting. The CLI reads the C host's
final checkpoint. Zig failure-injection tests run every allocation site through
creation, cut, serialization and restoration and check failed-cut atomicity.
These tests supplement the engine suite; they do not prove ABI correctness or
floating-point behavior. The existing Lean scope is unchanged.

Actual macOS dynamic-library and Windows DLL host runs passed in
[CI for the reviewed SDK commit](https://github.com/merkhet-io/menkh/actions/runs/41148405936).
The Windows cross-build also completed locally, but native CI execution—not the
cross-build—is the evidence that the host can load and call the DLL.
