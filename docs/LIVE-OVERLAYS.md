# Live exposure colors, targets and fixtures

Both native viewers can inspect these data in consistent, leased live windows.
The voxel state remains authoritative. Color changes do not alter cutting,
material metrics or geometry. The publication and viewer code is outside the
Lean model.

```sh
./scripts/live-inspection-demo.sh
# Smaller smoke configuration:
MENKH_VOXEL_MM=0.1 ./scripts/live-inspection-demo.sh
# Reproduce measurements without a viewer:
python3 scripts/live-demo.py --inspection --out out/inspection-job.json
python3 scripts/benchmark-live.py --job out/inspection-job.json --out out/inspection-benchmark
```

The inspection variant keeps the original 24 × 18 × 8 mm stock, ball tool,
2,501 continuous segments and 0.005 mm motion tolerance. Its larger
28 × 22 × 10 mm grid contains two separate fixture blocks. At 25 µm it has
1120 × 880 × 400 cells. The target is the stock footprint up to Z = 3.2 mm.
It is intentionally different from the curved path's result: excess/missing
colors are geometric target differences, **not simulation-error measurements**.

For another job, use `menkh-viewer job.json --live`. Target and fixture primitives,
STL inputs or saved states use the existing job schema. Set
`"export_provenance": true` for live exposure colors. This works with either
completed-history provenance scope; `final_surface` still applies only to the
completed archive. Live windows always retain attribution throughout their range.

## Controls

On macOS, use the exposure-color menu, target comparison checkbox, fixture/stock
visibility, section axis/slider and double-click material picking. To inspect the
target alone, hide stock and enable target comparison. Holding Follow latest
allows seeking through the retained range.

On Windows, click the 3D view for keyboard focus:

| Control | Action |
|---|---|
| C | Material / exposing operation / exposing tool colors |
| G | Same-grid target comparison: excess yellow, missing red, matching blue |
| F | Fixture visibility (green) |
| V | Target visibility |
| S | Stock visibility |
| X / Y / Z, then [ / ] | Select section axis and move its plane |
| Ctrl + left click | Pick occupied material and show world position and exposure IDs |
| N | Cycle reported shank/holder/fixture contacts in this retained range |

Picking selects material occupancy, ignoring tool and fixture overlays. A section
interior or an initial/prehistory face has no invented exposure ID. Target
comparison takes precedence over exposure coloring. Windows non-flat cutter
visualization remains unsupported; the material cut by those tools is supported.

Windows also accepts `--compare-target`, `--show-target`, `--hide-stock`,
`--hide-fixtures`, `--hide-tool`, `--section FRACTION`, `--section-axis 0|1|2`,
`--pick-center` and `--inspection-report FILE`. Inspection reports contain exact
raster excess/missing counts at the selected global operation, the optional pick,
and recorded contacts. These are geometric quantities, without feed/time rates.

## Attribution at a rebase

Each 16-byte entry stores an empty-neighbor cell key, a global operation ID and a
tool ID. Operation IDs are one-based positions in the original job. Tool ID zero
means no tool; other values are job tool index + 1. The visible face belongs to a
remaining voxel; its exposure belongs to the **removed neighboring voxel**.

The producer maintains a separate live index. At a new base checkpoint it retains
known entries adjacent to remaining stock and discards the rest. In monotone
subtraction a removed cell that no longer borders any remaining voxel cannot
become a material boundary later. Entries exposed during the retained window
are kept until the next rebase, even if their surfaces subsequently disappear.
This allows rewind without losing attribution.

Old IDs are not renumbered. Faces exposed before the retained range keep their
known numeric source IDs; the operation's textual name may no longer be present.
Initial/world boundaries and history preceding an imported checkpoint remain
unknown. This is not arbitrary history reconstruction. The viewer uses
`first_operation + local_frame` to gate exposure and never displays future labels.

A slot's `surface-provenance.json` uses `menkh-live-provenance-v1`, with grid,
origin, spacing, final occupied count, entry/byte counts, `first_operation`,
`completed_operations` and `tool_count`. The binary retains the existing sorted
little-endian `(u64 cell, u32 operation, u32 tool)` records. Completed histories
keep `menkh-surface-provenance-v1` and their existing operation metadata.
Both formats validate sizes, sorted unique cell keys and ID bounds.

## Immutable assets and findings

`live/assets/` contains target/fixture block and pool files, written once before
any pointer is published. The manifest's `live_assets` flag selects that fixed
sibling directory. All windows use the same grid origin, dimensions and spacing.
The producer never overwrites or removes these files, including after completion,
cancellation or failure. They remain with the run; the user must not delete the
run while inspecting it. Slot leases still protect mutable window files.

Each slot contains a `report.json` limited to its retained operations, labeled by
`first_operation`. Contact records belong to those operations. Shank/holder stock
checks use **pre-operation stock**, while the displayed tool pose is the segment
end pose. Intended cutter engagement with stock is not a collision; cutter/fixture
contact is a separate finding. Unresolved contacts remain labeled unresolved.

Target colors and optional counts evaluate the currently selected occupancy.
There is no live connected-defect-region computation or reuse of a stale final
`defects.json`. Completed-result region inspection remains unchanged.

## Resource and failure semantics

The existing `live_inspection` options gain:

```json
"max_provenance_bytes": 33554432,
"max_asset_bytes": 268435456
```

Both accept 16 bytes through 1 GiB. The provenance limit bounds the live entry-array
capacity; the asset limit bounds the combined immutable grid payload. The existing
`max_snapshot_bytes` also includes each slot's provenance binary/header and
retained findings. The three-slot publication bound and reader backpressure remain.

Limits fail explicitly with `ProvenanceTooLarge`, `LiveAssetsTooLarge` or
`LiveSnapshotTooLarge`; no partial index is advertised. A cutting operation can
have completed before inspection fails. The run then fails without a completed
result manifest; earlier published windows remain consistent and leased. This is
not rollback of the entire job. A separate full archive and completed-history
index can still grow with the job under their existing limits.

The report separates live extraction/pruning time, entry capacity, peak encoding
scratch and immutable asset bytes. Publication time includes file writes and
metadata work. Viewer logs record provenance/asset buffer capacities alongside
material, upload and process memory. Native renderers currently reload these
buffers between windows; temporary old/new buffers can coexist. Capacity figures
are not total RSS, GPU duration is not interactive FPS, and cached writes are not
durable-storage measurements.

Measured 25 µm timings, memory, raw records and actual screenshots are in the
[evidence report](evidence/live-overlays/README.md).

## Validation

`scripts/test-live-overlays.py` independently decodes archived deltas into cell
sets and records removal chronology. It checks every frame of sampled windows,
including rebased base states, against all currently exposed faces. It includes
an enclosed cavity, disconnected material, non-grid-aligned cuts, overlapping and
idempotent operations, two tool IDs, held readers, resumed following, immutable
assets, explicit resource failures and final checkpoint equality. Same-grid
excess/missing counts are checked against direct set differences in both readers.

Windows CI additionally renders colors, comparison and sections from captured
windows and runs the actual live controls with provenance/target/fixture data.
Local Metal validation covers the independent oracle, captured windows and the
25 µm live demo. Existing completed-history provenance, transport, engine tests
and Lean/audit/bridge checks remain part of validation. The new pruning and
publication algorithms are not claimed to be formally verified.

## macOS live presentation

The native live window retains its controls and Metal drawable layer across
publications. A single background loader validates the next leased history and
prepares buffers while the current state remains visible. The Metal pipeline and
device are reused. During playback, zooming, dragging or inspection changes,
adaptive rendering caps the drawable at 1280 × 900 display pixels with the window
aspect ratio preserved. Following an active calculation keeps this motion quality
even between slow publications. Hold, pause or completion permits sharp inspection.
After 350 ms without activity it redraws once at full
native backing resolution, then suspends idle GPU rendering. Activity resumes
continuous rendering. The delay prevents quality switching between normal live
publications. Use `--live-native-resolution` to keep full backing resolution even
during motion. This also applies to completed voxel-history playback. Display
sampling never changes voxel occupancy, picking coordinates, exports or material
metrics. Camera and inspection modes are copied at handover, so camera
input received during preparation is preserved. Both leases survive handover;
holding Follow latest discards any in-flight prepared replacement.

Following polls at a minimum 150 ms interval and plays available recorded states
over a 120 ms catch-up interval, on a 60 Hz requested UI timer. Completed-history
playback advances at up to 30 operations/second. These are presentation settings,
not physical feed rates or achieved frame-rate guarantees. Material and exposure
IDs always correspond to a recorded operation; no surface interpolation is used.
If the producer has advanced beyond the retained range, playback must jump to its
new base. Large individual cuts and expensive ray casting can still cause visible
steps. The Windows presentation path is unchanged by this macOS fix.

Validate a completed native run with:

```sh
python3 scripts/check-live-presentation.py --result out/new-live-run --reference out/reference-run
```

This checks stable view handover, monotone displayed operations, actual draws
between updates, and exact final checkpoint bytes. Logged draw-callback gaps are
diagnostics, not displayed-frame timing or interactive FPS.

Actual presentation diagnostics, including unfavorable intermediate results, are
in the [presentation evidence](evidence/live-presentation/README.md).

The idealized cutter uses steel-like display lighting with a camera-relative key
highlight. Its silhouette and collision/cutting geometry are unchanged; no flutes
or other nonexistent geometry are painted into the material model.

The adaptive sizing policy runs in macOS CI. A native Metal integration check is
available with `menkh-viewer HISTORY.json --verify-adaptive-presentation REPORT.json`;
it verifies capped movement, native-resolution idle rendering, resumed motion,
the full-resolution override and byte-exact occupancy preservation.
