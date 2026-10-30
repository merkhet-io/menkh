# General engine architecture and accuracy

The original fast constant-Z API remains in `core.zig`. The new `engine.zig` implements reusable analytic geometry, tool sweeps, primitive stock unions, transactional subtraction, reversible changes, and checkpoint compaction. Both drill demos now construct their shapes through this engine. `fine.zig` is a demo/history writer rather than a separate cutting implementation; the 24 mm drill translation lives in demo configuration only.

`job.zig` loads strict versioned JSON and coordinates initialization, operations, reports, history, exports, targets, and fixtures. `state.zig` owns checkpoint encoding and transactional replay. `mesh_input.zig` imports/voxelizes closed binary STL through a BVH. `inspect.zig` provides independent read-only queries and bitwise comparisons. `motion.zig` builds bounded arc/helical sweeps and explicit turning envelopes. `tiles.zig` is an immutable inspection-layout experiment, separate from mutable stock.

## Coordinates and occupancy

`Grid.origin` is the world/workpiece-local lower corner. Voxel `(i,j,k)` has center `origin + h × (i+0.5,j+0.5,k+0.5)`. The finite domain uses the original center-in-half-open-domain rule, including partial boundary blocks. `Grid.center(i)` deliberately remains a local scalar helper for legacy callers; `query` and exported vertices include the origin. The optimized original end-mill API translates world input to local coordinates before testing.

Stock primitives use closed surfaces with absolute 1e-10 mm predicate tolerance, clipped to the finite grid domain. Domain clipping itself follows the center rule. Different stock primitives are unioned, never added as floating-point volume estimates. Subtraction clears bits; disconnected pieces and enclosed cavities need no special representation. Primitive signed distances are evaluated analytically at centers; there is no stored or resampled signed-distance material field.

Geometry uses `f64`, normal IEEE operations, positive finite dimensions, and coordinates bounded to ±1e6 mm. Unit axes must have length within 1e-10 of one; they are not silently normalized. Prefer small coordinates. The fixed absolute tolerance is significant for extremely small features; arbitrary scales do not inherit an industrial accuracy certificate.

## Tools and continuous motion

Tool position is the bottom tip/face center, and the unit axis points toward the shank. Flat tools are finite cylinders. Ball tools contain a lower hemisphere of radius R centered at axial coordinate R and a cylindrical flute above it, up to `length >= R`. Bull tools have corner radius C, a flat bottom of radius R−C, a quarter-circle corner and a cylindrical flute. Tapers are truncated cones between `tip_radius` at Z=0 and `radius` at Z=length. The idealized drill is a full cone with its tip at Z=0; it is not a manufacturing-ready drill assembly.

The flat-tool straight sweep is analytic for any fixed axis: intersect the motion parameter interval satisfying both axial caps with the interval satisfying the radial quadratic. A moving finite cylinder is not replaced by a capsule. Stationary, reversed, split and tilted sweeps have independent test coverage. The legacy vertical XY capsule-volume fast path remains available and measured separately.

For other tools, sample the straight centerline at spacing at most 2ε, including both ends, and dilate the exact tool solid at each sample by half the actual spacing. The nearest sample is at most that dilation away from every continuous pose. Therefore the union contains the continuous sweep, and any extra point is at most that dilation from the continuous swept solid, before numerical tolerance and voxelization. This is an explicit conservative construction, not unexpanded isolated stamps. Stationary tools have zero motion approximation. The implementation uses analytic tool distance, including the flute.

Arcs/helices are defined by an orthonormal plane basis and rise along its normal. A chord with angle Δ has deviation `R × (1 − cos(Δ/2))`; linear rise adds no chord deviation. Chord error is limited to ε/4. Each chord sweep is additionally dilated by that error, with non-flat pose spacing budget ε/4. Flat sweeps expand radial and axial constraints; their Euclidean over-removal is bounded by √2 times the dilation. The reported total includes both the chord-to-curve deviation and sweep dilation. It is no larger than the requested tolerance for the supported planner. All subsegments are applied as one transactional union operation. Arc assemblies with shank/holder geometry and arc feed rates are rejected explicitly in this version.

Sampling subdivisions can differ when an approximate motion is split into multiple jobs. Exact split invariance is tested for analytic flat sweeps; approximate split jobs retain their error bounds but need not produce identical boundary voxels. Simultaneous orientation changes are rejected. There is no implicit orientation interpolation or quaternion convention to misinterpret.

## Allocation, mutation and history

The dense u32 block directory and pooled eight-u64 bitfields remain authoritative. Subtraction first validates geometry, bounds candidate blocks, counts required pool/history capacity, and reserves it. Only then does the write pass clear occupied bits. No allocations occur inside voxel loops. Failure during validation/reservation leaves occupancy unchanged; allocation capacity may have changed. Shape/arc planning also completes before mutation. Initializers are unpublished until successful and free partial allocations on failure.

Conservative block tests use convex corner inclusion, center-distance Lipschitz exclusion, radial bounds, or linear plane extrema. A full block materializes only for partial removal. Empty blocks are skipped. The scalar reference bypasses block classification but evaluates the same declared occupancy semantics; separate analytic/profile/time-sampling oracles address shared-predicate mistakes.

Slots are not reused during a history. Delta records carry old/new descriptors and bitfields. `state.replay` validates record structure, increasing IDs, bounds, edge bits, expected current values, and slot ownership before reservation and mutation. Compaction builds a fresh pool and switches only after allocation succeeds. It invalidates old slot-index history and is therefore exposed as an explicit checkpoint operation. A resumed job starts new history. No automatic compaction invalidates playback.

Jobs are sequences of transactional operations, not a transactional filesystem/database. An export or later-operation failure may leave earlier output files. Only a successfully completed run's manifest/report should be consumed. Use separate output directories for independent runs.

## Inspection and collision semantics

Removed volume, remaining volume and per-operation engagement are integer counts times h³. Reports name each operation and provide a conservative affected block region in world mm. Repeated removal contributes zero engagement. Straight-line length/feed is reported only when feed is supplied; it excludes acceleration, rapid transitions, dwell and all controller behavior. Zero-length motion has zero geometric time and no removal-rate quotient.

A target uses exactly the same origin, dimensions and voxel spacing. Excess is `stock & ~target`; missing material is `target & ~stock`. A missing region may predate cutting if the initial stock did not cover the target. Volumetric differences are not local accuracy bounds. For a single analytic target primitive and an exported mesh, face corners and centers give separate sampled absolute surface distances. This is not a continuous Hausdorff measurement. General imported-target surface distances remain unsupported; its raster volume comparison works.

Shank and holder are separate finite cylinders starting at or above the cutter's axial extent. They never remove material. They are checked along the continuous fixed-orientation straight path against pre-operation stock and separately against fixtures. Cutter engagement with stock is intended; cutter intersection with a fixture is reported. A reported intersection means occupied centers intersect the declared swept region. Absence of such centers does not certify subvoxel clearance: `representation_clearance_uncertain` remains true. Fixtures use their own voxel grid, not a noncutting label on the stock.

Ray queries traverse the voxel union and return its first occupied face, position, index and distance. Sections sample arbitrary orthonormal planes into PPM images; their pixel spacing is independent of voxel spacing. The Metal viewer provides Z clipping and occupied-material picking. Display calculations use `f32` and a traversal epsilon; rendered/picked display positions are not certified metrology.

## Turning envelope

The turning mode has explicit spindle origin/axis and a rectangular ideal insert in radius/axial coordinates. A longitudinal pass keeps its inner radius fixed; a facing pass keeps its axial start fixed. Sweeping the rectangle and assuming complete rotation at every path position yields an annular cylindrical envelope, evaluated at voxel centers. This is a full-revolution envelope approximation, not discrete spindle-angle simulation. It cannot model interrupted angular cuts, finite spindle speed, insert nose radii, synchronized threads, or turret kinematics.

Milling and these envelopes can update the same state. Tests cover a translated, tilted spindle and subsequent milling. This supports geometric composition only; it is not a production mill-turn SDK claim.

## Five distinct error sources

1. **Input:** analytic definitions are exact idealizations; STL float32 coordinates and tessellation already approximate the intended CAD surface. Units/scaling are explicit.
2. **Motion:** zero for analytic flat straight sweeps; explicit conservative dilation bounds for other straight tools and arc/helical operations.
3. **Occupancy:** center-sampled cells, volumes h³. Thin features can disappear, and disconnected topology can change below the grid scale.
4. **Surface:** OBJ represents the voxel union without smoothing. Greedy merging can create T-junctions; unit-edge closure and oriented volumes are checked. Nonmanifold voxel contacts remain possible. Lighting-normal averaging changes no vertices or metrics.
5. **Floating point:** `f64` predicates with absolute tolerance and conservative block clearance, `f32` display. No formal interval-arithmetic bound is claimed.

The sphere experiment reports sampled vertex deviation at 250/100/50/25 µm. For this unclipped analytic fixture, the half-cell diagonal is also a one-sided voxel-boundary-to-analytic-boundary bound under exact center classification. It is not a general two-sided Hausdorff bound and says nothing about analytic features with no occupied samples. A 25 µm grid is not a universal 25 µm maximum-error guarantee.

## CPU fast paths

Canonical +Z flat sweeps use tight bounds. Constant-Z sweeps reuse XY masks across
axial layers and use f64 SIMD for dense rows. A preflight classification array
(one byte per candidate block) is reserved before mutation and reused by the
write pass; it is recomputed for every operation. Collision inspection uses
bounded block traversal, shared masks, popcounts and exact occupied-center
extrema. A full-grid scalar collision oracle remains available for tests.

The scalar subtraction path retains the broad bounds and per-voxel predicate.
No new motion approximation, changed tolerance or history-slot reuse is involved.
See [CPU-PERFORMANCE.md](CPU-PERFORMANCE.md) for measured gains, memory costs and
restrictions. Parallel predicate benchmarking does not enable parallel cutting.

Eligible +Z flat sweeps also include pure vertical translations. Axial membership
retains the reference's time-interval arithmetic; XY masks and classification are
cached per XY block column for each operation, never reused across operations.
`Changes.flat_columns` capacity is reserved in preflight and released in deinit;
its capacity is included with classification bytes in `cut_scratch_capacity_bytes`.
No pool slots or history records are reordered. PPM height export resolves 64
columns per block tile with word operations and preserves the prior pixel mapping.
