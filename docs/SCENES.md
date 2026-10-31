# Named scene objects and independent workpieces

This is a small typed scene layer, not a generic ECS runtime. Scene objects have
stable string IDs, a role, a geometry-resource reference and a placement. Tools
are named assembly resources. Workpieces additionally bind a target and fixture
IDs and own a local material state. Voxels and blocks remain compact arrays and
pooled bits inside the existing engine; they are not entities.

## Run and inspect

On macOS, `./scripts/scene-demo.sh` builds and runs the two-workpiece example in a
fresh temporary directory and opens a workpiece chooser. Direct commands:

```sh
./zig build -Doptimize=ReleaseFast
zig-out/bin/menkh scene examples/two-workpieces.json --out out/two-parts
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/two-parts/scene.json --workpiece left --color-operation
zig-out/bin/menkh-viewer out/two-parts/scene.json --workpiece right --compare-target
```

The Windows CLI accepts the same scene command. Its native viewer opens the result
with `menkh-viewer.exe out/two-parts/scene.json --workpiece right`. On macOS the
selection argument is optional: a dialog lists workpieces. Windows requires it
when there are multiple workpieces. Both viewers retain normal playback, picking,
comparison and section controls for the selected workpiece. The UI labels its ID
and scene translation; picking and reports use **workpiece-local coordinates**.

The example reuses one blank, one target and one clamp geometry resource. Two
workpieces have distinct placements, targets and fixture bindings. The right target also has a subvoxel offset. Both receive
a ball-end groove; only the left receives the additional hole. Their voxel states
remain independent even though they reference the same initial geometry.

## Schema and coordinates

The input format is `menkh-scene-v1`, version 1, with `units: "mm"`, voxel spacing,
motion tolerance and these arrays:

- `geometries`: `{id, source}`. `source` uses the existing job stock schema: a
  primitive union, binary STL reference or saved state. Input file paths resolve
  relative to the original scene file, including when intermediate jobs are
  written elsewhere.
- `objects`: `{id, role, geometry, translation_mm}`. Roles are `workpiece`,
  `fixture` or `target`. A workpiece also requires local grid `bounds`; optional
  `target` and `fixtures` fields reference scene object IDs. Other roles cannot
  own these workpiece-specific fields.
- `tools`: `{id, assembly}` using the existing cutter/shank/holder definition.
- `operations`: `{id, workpiece, tool, line}` or `{id, workpiece, subtract}`.
  The workpiece and tool fields are IDs, not array positions.

IDs must be nonempty UTF-8 strings of at most 128 bytes and unique within each
array's namespace. Output paths are generated from numeric slots, never IDs.
Reordering objects does not change their identity or the material they own.
Numeric provenance IDs remain local job operation/tool-table indices; original
operation strings and the scene tool table provide the named mapping.

Geometry and grid bounds are local to each object. Object placement is a static
translation. Motion endpoints and subtraction geometry are in scene coordinates:

```
scene point = local point + translation_mm
local tool position = scene tool position - workpiece.translation_mm
local fixture placement = fixture.translation_mm - workpiece.translation_mm
```

Tool axes are unchanged by translation. Existing fixed-orientation straight-sweep
semantics and tolerances apply, including fixed tilted tool axes. All operations
for a workpiece retain their original relative order. Unrelated workpiece streams
are executed sequentially in object order; this is not a synchronized timeline.

Targets use the same local grid as their workpiece. Their comparison is limited
to that grid's bounds, as in ordinary jobs. Bound fixtures currently require
primitive geometry and must fit completely inside the workpiece grid; clipping
one is rejected. A translated auxiliary saved-state grid is rejected rather than
resampled. A saved state used as stock must already match the local grid.

## Ownership and outputs

`src/scene.zig` validates IDs, references, roles and supported transforms, then
compiles each workpiece into an ordinary job. Each job owns and releases its own
grid, pool, target, fixture union and history. Only one workpiece's simulation is
resident at a time. Compilation metadata uses an explicit arena. There are no
new allocations in the voxel loop and no changes to cutting/pool/history kernels.

The output directory must be new. It contains generated local jobs and separate
`workpiece-NNNN/` result directories with checkpoints, reports and histories. A
`menkh-scene-result-v1` catalog (`scene.json`) is written only after all workpieces
finish, with stable IDs, placements, object/tool bindings and original scene
operations. The viewers consume this catalog to resolve the selected history;
they do not need the original geometry files to inspect completed results.

Preflight errors occur before output creation. A later file/allocation/simulation
failure may leave completed workpiece directories, but no completed scene catalog.
There is no scene-wide rollback. Reusing an output directory is rejected, including
when its previous run failed. Generated jobs are diagnostic local-coordinate
inputs; relative source files still belong to the original scene directory.

## Deliberate boundaries

- No rotations/scales, transform hierarchy, moving fixtures, parenting or arbitrary
  component attachment. Unknown JSON fields and unsupported motion variants fail.
- No cross-workpiece collision or cutting: an operation affects only its named
  workpiece. Other workpieces are not automatically fixtures. Even spatially
  overlapping workpieces remain independent resources.
- Fixture collision reports refer to the bound fixture union, not an individual
  fixture ID. There is no per-fixture visibility toggle yet.
- No combined assembly viewport, synchronized multi-workpiece scrubbing, scene
  live runner or scene C ABI. Existing single-job live inspection and C ABI remain
  unchanged. Multiple ordinary result viewers can be opened for separate parts.
- No speedup claim or expanded formal-proof scope. This is ownership/coordinate
  organization, not a change to voxel material semantics or machine kinematics.

## Validation

`python3 scripts/test-scene.py --reader out/history-test` compares the translated
example against independently specified local jobs. It checks byte-exact states,
auxiliary grids and provenance, contact/volume reports, distinct ownership,
reordered IDs, relative STL resources, saved-state reuse and invalid input.
Zig tests cover independent translated-sphere membership, half-space offsets and
allocation-failure cleanup. Portable viewer tests reject escaping catalog paths.

The macOS viewer was built and used to render the left part and replay the right
part forward/backward/forward. Windows CI is configured to compile both MSVC entry points, select
both catalog objects and render them using D3D12 WARP. CI does not establish
hardware GPU performance or full multi-object rendering.
