# Imported ball-end finishing

Run the full protocol (several minutes on the measured M5 Max):

```sh
python3 scripts/finishing-workflow.py
```

The smoke configuration retains the same STLs and all 5,199 segments, using
250 µm instead of 25 µm:

```sh
python3 scripts/finishing-workflow.py --smoke --out out/finishing-smoke
```

`--no-viewer` runs without a graphical session. `--skip-build` uses the current
ReleaseFast executable. Both modes run warm-up plus two measured repetitions,
midpoint checkpoint/resume, compaction/resume, canonical occupancy comparison,
and geometric inspection. Full mode additionally runs the resolution matrix and
analytic accuracy fixture and a tighter 1 µm motion-tolerance diagnostic. The native viewer saves final, comparison, X/Y section
and tool-assembly images, verifies complete history replay and measures loading,
seeking and offscreen GPU durations. No global dependencies are installed.

The generator deliberately lives outside the engine. It is an example finishing
path, not a CAM collision-avoidance algorithm. Binary STL input and voxel occupancy
remain authoritative. The stock is pre-roughed, not a full-height billet. See the
[frozen protocol](FINISHING-PROTOCOL.md) for dimensions, formulas and budgets.

## Mesh import

The original three-direction BVH parity classifier remains unchanged and available
through `--reference`. Mesh parsing, edge-manifold validation, BVH build and
self-intersection validation have separate timing fields. No holes are repaired.

Optimized voxelization first tests whether any triangle AABB overlaps the box of
voxel centers. A triangle intersecting that box necessarily has an overlapping
AABB. Therefore, no overlap establishes that the connected box lies entirely in
one inside/outside component. Only then is a single parity query used to fill or
empty the region. This argument applies to disconnected shells and enclosed
cavities, not just height fields. Conservative false overlaps cost time but cannot
cause an entire boundary block to be filled incorrectly.

Surface-adjacent 8³ blocks are recursively divided along the longest index extent.
The same exclusion argument is used at each level, down to individual centers.
This is bounded stack traversal inside a block (depth <= 9), not an octree storage
replacement. Boundary blocks retain their valid-bit masks. Failed import destroys
the unpublished grid; allocation failure does not publish partial stock.

## Ball sweeps

The scalar implementation still enumerates exactly the original n+1 poses with
n=ceil(segment length / (2*tolerance)). Each pose uses the complete hemispherical
plus finite-cylinder cutter and the original signed-distance arithmetic. Subtracting
half a pose spacing from the minimum distance conservatively covers continuous
translation. The resulting over-removal bound is that half-spacing (plus explicitly
requested dilation), independently of voxel spacing.

The complete ball cutter is convex. Its signed distance restricted to a translation
line is convex, so adjacent sample distances bracket the minimum on the discrete
pose lattice. The optimized path narrows the bracket and exhaustively evaluates
its final <=9 samples. It retains the original floating-point pose construction;
it does not silently replace the sampled/dilated sweep with an exact capsule.
Other non-flat tool families retain exhaustive evaluation. Fixed +Z tools also
use a tighter radius/axial-length bounding box. General tilted ball tools still
use the existing broader spatial bounds.

Block exclusion/inclusion uses the distance's Lipschitz bound with the existing
numerical guard. Partial-mask counters report actual voxel queries and actual
point-pose evaluations. They exclude block-classification distance evaluations
and noncutting collision checks; they are not universal voxel-tests-per-second.
A warm-up CPU sample captures the actual cutting call stack when `sample` is
available. End-to-end timings remain the performance result.

## Storage, history and inspection

Descriptors and mutable pooled bitfields are retained. No pool slots are recycled
while history references them. Files contain only changed descriptors and bitfields;
the viewer applies changed ranges to shared Metal buffers. Only one GPU command is
in flight before CPU history changes. Checkpoints store full material state;
compaction creates a new state whose subsequent history starts a separate timeline.
Old deltas are never replayed on compacted slot numbering.

Canonical state digests compare represented occupancy, including valid bits of
partial edge blocks, rather than allocation order. Native history verification
compares initial descriptors/live initial pool bytes and final descriptors/full
final pool bytes after forward/backward/forward traversal.

The viewer now displays the complete ball cutter and offers X/Y/Z sections. Existing
world-coordinate picking, operation slider, target excess/missing colors, assembly
visibility and lighting-only normal averaging remain available. Rendering normals
do not change occupancy or reported material volume.

## Accuracy and proof boundary

The independent analytic oracle minimizes the lower intersection of a moving sphere
along a straight segment using a separately derived algebraic stationary point.
In the selected fixture, the upper flute extends above the stock throughout, so
this envelope defines the machined top contour of the complete tool. Separate tests
exercise flute points and continuous-motion coverage. The contour experiment does
not independently validate arbitrary tilted finite-tool caps.

Contour distances are bidirectional distances between samples in two XZ sections,
not certified 3D Hausdorff distances. Ideal spacing is 0.01 mm, with samples along
jump faces; raster samples include top-edge centers and vertical step centers.
Coarse-grid disappearance of a narrow rim is reported as feature loss. Vertical
height samples on the imported fixture separately compare input triangulation,
designed path, and raster output. They are not Euclidean nearest-surface distances.

Lean theorem scope is unchanged. The new mesh traversal, discrete convex search,
STL classifier, Swift viewer and executable are not covered by an implementation
refinement proof. Existing proofs/audits/bridge tests remain regression evidence
for their documented mathematical model only.
