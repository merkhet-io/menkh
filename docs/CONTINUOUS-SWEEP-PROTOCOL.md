# Continuous profiled-wheel sweeps: frozen experiment

Baseline: `e4dfed2` (PR #46 README refresh), Zig 0.15.2, macOS Apple Silicon.
The unchanged screw has a 12 mm diameter × 40 mm blank, two starts, four turns
per start, 1,024 XYZAC line segments, and the crown profile defined in
`grinding_demo.zig`. Evaluate 250, 100, 50 and 25 µm XY ray spacing with the same
10 µm requested motion tolerance, eight workers, no history/provenance/mesh in
cutting measurements. Retain the existing fixed/axis/adaptive methods.

Implement the continuous translation of a complete convex finite profile at
fixed orientation. A swept sphere/capsule is not a replacement for the wheel.
Intersect rays against the convex swept body using endpoint tools, swept profile
rim circles and swept conical silhouette generators. Keep an independent point
oracle: a point belongs to a translation sweep exactly when its reverse-motion
line intersects the stationary tool. Include analytic cylinder cases as a second
independent geometric oracle.

For XYZAC motion, subdivide orientation only. Within a subsegment, hold the true
midpoint axis and sweep translation continuously. Bound axis path length using
rotational symmetry, inflate by its maximum midpoint deviation, and account for
both conic miter expansion and distance back to true motion. Report the achieved
bound separately from ray spacing and numerical guard. A changed approximation
may change final intervals; quantify it rather than claiming byte identity with
midpoint-pose unions.

Acceptance: Debug/ReleaseFast tests; stationary, axial, transverse, oblique,
short, reversed, split, tilted, tangent and randomized cases; no inner-loop
allocations; checked preflight storage; deterministic workers; exhaustive versus
pruned results; independent continuous-motion coverage/distance tests. Run the
complete 25 µm workload and compare repeated timings, phase costs and memory.
Keep slower variants and failures. A method is not promoted just because fewer
sweeps are prepared. New algorithms remain outside the Lean model.

One warm-up plus at least three alternating repetitions, identical starting stock
and output settings. Record executable/source identities and validate outputs.
Export and inspect an actual smaller mesh separately; do not count display
smoothing as geometric improvement. Do not change the workload after an
unfavorable result or infer a performance ratio against Jens's unmatched timing.
