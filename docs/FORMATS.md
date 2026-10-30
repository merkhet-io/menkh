# Job, state and geometry formats

## JSON job version 1

Run `./zig build job -Doptimize=ReleaseFast -- examples/general.json --out out/general`. See the complete [general example](../examples/general.json), [helix](../examples/helix.json), and [turning envelope](../examples/turning-envelope.json). Unknown fields, malformed unions, invalid dimensions and unsupported operations are errors. Paths are relative to the process working directory, not the job file.

```json
{
  "version": 1,
  "units": "mm",
  "bounds": {"lo": [-4,-4,0], "hi": [4,4,8]},
  "voxel_mm": 0.1,
  "stock": {"primitives": [{"cylinder": {"base": [0,0,0], "radius": 3, "length": 8}}]},
  "tools": [{"cutter": {"kind": "ball", "radius": 1, "length": 4}}],
  "motion_tolerance_mm": 0.025,
  "operations": [{"id": "ball-ramp", "tool": 0, "line": {
    "a": {"position": [-2,0,4], "axis": [0,0,1]},
    "b": {"position": [2,0,5], "axis": [0,0,1]}
  }}]
}
```

`stock`, optional `target`, and optional `fixtures` each choose exactly one source:

- `primitives`: nonempty union of `box {lo,hi}`, `sphere {center,radius}`, `cylinder {base,axis?,radius,length}`, `capsule {a,b,radius}`, `halfspace {normal,offset}`, or `annulus {base,axis,inner,outer,length}`. The default cylinder axis is +Z. Halfspace means `dot(normal,p) >= offset`.
- `stl: {path, unit_scale_mm, translation?}`: binary STL with required explicit units. No silent repair or inferred inches.
- `state_file: "out/previous/final.menkh"`: resume an exactly matching grid. New operations start a new history.

A tool assembly contains `cutter` and optional `shank`/`holder`, each noncutting component `{radius,length,offset}`. Cutter fields are `kind` (flat default, ball, bull, taper, drill), `radius`, `length`, `corner` (bull only), and `tip_radius` (taper only). Unused nonzero parameters are rejected. Pose `{position,axis}` uses a unit axis, default +Z.

Each operation has a unique nonempty `id` and one geometry definition:

- `tool` index with `line: {a,b}` poses. Axes must be identical. Optional `feed_mm_min` supplies geometric length/feed timing.
- `tool` index with `arc: {center,u?,v?,radius,start_angle,sweep_angle,rise?,axis?}`. Angles are radians. Defaults: XY plane, zero rise, +Z tool axis. The plane basis must be orthonormal. Signed sweep allows both directions, up to 32 revolutions. Arc shank/holder and feed inputs are currently rejected.
- `subtract`: one primitive, for explicit geometric removal.
- `turning`: `{spindle_origin,spindle_axis?,mode,radial_start,radial_end,axial_start,axial_end,insert_radial_width,insert_axial_width}`. Mode is `longitudinal` or `facing`; the other coordinate stays constant. This invokes the full-revolution envelope described in [ENGINE.md](ENGINE.md).

Optional `points` contain `{point}`. Optional `rays` contain `{origin,direction,max_distance_mm}` with unit direction. Optional `sections` contain `{origin,u,v,pixel_mm,width,height}`; pixel centers sample the plane from its corner origin. `export_mesh` defaults to true; disabling it avoids surface generation and sampled target-surface analysis. Height PPM, final state, report and history are still exported.

Outputs include `report.json`, `height.ppm`, optional `surface.obj`, `section-N.ppm`, `final.menkh`, and `voxel-animation.json` plus block/pool/delta files. All voxel-derived volumes are raster approximations. Reports separate initialization, auxiliary voxelization, cutting, collision queries, statistics, section/query inspection, surface generation, surface analysis, state/image/OBJ export, and history writes. JSON/manifest serialization and final report write are not included in the recorded phase totals. No `fsync` is performed.

## State checkpoint v1

All integers and IEEE-754 fields are little-endian. Header size is 96 bytes:

| Offset | Content |
|---:|---|
| 0 | Eight ASCII bytes `MENKHST1` |
| 8 | Origin: 3 × f64 |
| 32 | Domain size: 3 × f64 |
| 56 | Voxel spacing: f64 |
| 64 | Descriptor count: u64 |
| 72 | Pool slot count: u64 |
| 80 | Wyhash(seed=0) of payload |
| 88 | Wyhash(seed=0) of header bytes 0–79 |
| 96 | Descriptor array: count × u32, followed by slots × 8 u64 |

Descriptors use `0xffffffff` empty, `0xfffffffe` full, otherwise pool index. Dimensions are recomputed from validated domain/spacing. Import validates exact file size, arithmetic, checksums, finite coordinates, slot bounds, duplicate active slot references, and boundary padding. Unreferenced history slots may remain. Wyhash detects accidental corruption; it is not authentication. The CLI reads files up to 1 GiB.

`zig-out/bin/menkh compact-state INPUT.menkh OUTPUT.menkh` writes a compact checkpoint. Its occupancy is unchanged, but pool indices change. Discard the previous history and start a new job/history from that checkpoint. Never apply old deltas to it.

## History v1 and native viewer

The existing `menkh-voxel-history-v1` manifest is extended with optional `origin_mm` and `motion_tolerance_mm`; absent origin means zero for old demos. `grid` and `block_grid` have three independent dimensions. `stock_min/max` specify scene bounds. The viewer accepts dimensions 1–4096, including partial edge blocks.

`initial.blocks` is the complete descriptor array. `initial.pool` contains initial slots. Each frame references a `.delta` consisting of increasing block IDs. Each record contains u32 block ID, u32 old descriptor, u32 new descriptor, then 64 old bitfield bytes if old is mixed and 64 new bytes if new is mixed. Slots are never recycled during history. Frames include occupancy, changed-block count, byte count, operation label and endpoint tool position; general jobs additionally include axis and optional noncutting components. History is operation-level, precomputed playback, not feed-time animation.

Optional `target.blocks/pool` and `fixture.blocks/pool` store separate rasters with the same grid. The viewer uses them for comparison colors and fixture visibility. They are rendering/inspection resources; the stock remains authoritative. Core state files have stronger integrity checks than these lightweight playback resources. Do not treat arbitrary third-party history as a signed or trusted interchange format.

## Binary STL restrictions

Input must have an 80-byte header, u32 triangle count, and exactly count × 50-byte records. Counts are checked and limited to one million triangles. Coordinates and stored normals must be finite; transformed coordinates must lie within ±1e6 mm. Normals are not trusted for orientation. Zero-area/degenerate triangles, nonzero attribute bytes, open/nonmanifold edges, inconsistent edge winding, and detected triangle intersections are rejected. Vertices are matched by exact transformed coordinates; no welding, hole filling or repair occurs.

A median-split triangle BVH accelerates intersection checks and parity rays. Point membership uses odd/even shell parity; nested closed shells can represent cavities regardless of shell orientation. Boundary points within the absolute predicate tolerance are occupied. Rays hitting edges/vertices are retried with deterministic alternative directions. Conflicting valid parity results or exhausted retries report `AmbiguousMesh`. Voxelization aborts and frees unpublished stock on any classification error.

The validator is a floating-point triangle/edge validator, not a certified exact-predicate solid kernel. Degenerate contacts, nearly coincident shells and extremely small features can be rejected or remain numerically unresolved. There is no general CAD topology repair, STEP import, or guarantee for adversarial triangle soups. A closed mesh's tessellation error remains separate from voxel error. Tests and benchmarks include a box, rotated concave fixture, enclosed cavity, open mesh, intersecting shells and allocation failures.
