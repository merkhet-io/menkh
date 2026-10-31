# Analytic ray-interval grinding experiment (frozen protocol)

Base: `6d5bd1a`, Zig 0.15.2, macOS Apple Silicon. Preserve the production voxel
engine and both existing dexel/voxel benchmarks. This experiment tests a different
geometry algorithm, not merely another occupancy container.

Use the existing 12 × 40 mm, two-start, four-turn screw: 1,024 XYZAC segments,
crowned profile (0,7), (0.8,8), (1.2,8), (2,7) mm, 0.01 mm motion tolerance.
Measure ray spacing 0.25, 0.1, 0.05 and 0.025 mm. Do not change the workpiece,
path or declared tolerance after seeing performance. Higher resolution is optional
and must be an actual completed run, not an empty virtual-world result.

Architecture under test:
- Continuous material intervals along Z rays; sparse occupied XY columns.
- Convex piecewise-linear radius profile represented by axial slabs and conic
  inequalities. Nonconvex/waisted profiles are explicitly rejected initially.
- Direct analytic ray/offset-tool interval intersection, no recursive voxel-center
  subdivision. A temporal/spatial hierarchy rejects tool groups per ray.
- Batch final-stock evaluation reorders subtractive operations, using union
  commutativity. It deliberately does not yet provide history, engagement per
  operation, arbitrary stock import or viewer integration.

Motion is covered by inflated midpoint poses of bounded rotary subintervals.
Conic constraints use outward offsets. Their intersection contains the Euclidean
inflation but can add miter over-removal: report the additional bound from adjacent
meridional normal angles. Reduce planning tolerance as needed to keep the total
bound within 0.01 mm. This changes occupancy semantics versus the voxel reference;
never claim byte equality unless actually measured. Ray spacing, motion error,
float guards and surface/export error are distinct.

Validation: independent cylinder and crown ray intersections, tilted/transformed
rays, caps/tangencies, nonconvex rejection, interval subtraction with disconnected
material, allocation-failure cleanup, BVH versus exhaustive pose traversal, dense
original-tool checks for coverage and offset error. Compare rasterized center
occupancy against existing checkpoints and report both disagreement directions.

Measure planning, hierarchy build, interval cutting, statistics, export and oracle
comparison separately. Record tool-pose/ray/node counts, interval/column counts,
allocated capacities and RSS. Warm up and repeat kernel runs. Compare kernel times
with kernel times; omitting history/provenance/rendering is not an end-to-end win.
Retain regressions. Existing formal proofs do not cover these algorithms.
