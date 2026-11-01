# Continuous convex-profile translation sweeps (stage 2)

`menkh raydexel-bench --method sweep` is an experimental CPU interval kernel.
It retains the complete finite profiled wheel, including its flat caps. It does
not replace the tool with a sphere or approximate a translation by isolated
placements. Existing `fixed`, `axis` and `adaptive` methods remain available;
`fixed` remains the default. This is a final-stock batch experiment, not the
native voxel viewer's history engine.

## Geometry

For a convex solid of revolution K at fixed orientation and translation vector d,
the swept body is the convex Minkowski sum K + [0,d]. Profile radii must be positive
at both caps, with nonincreasing piecewise-linear slopes. At most 256 conical
patches are accepted by the sweep preparer. Nonconvex tools are rejected.

The ray solver constructs boundary candidates from:

1. The two endpoint tools.
2. Every profile rim circle translated along the segment. Eliminating the axial
   equation leaves a quadratic equation for ray or motion position.
3. Conical silhouette generators translated along the segment. For profile slope
   m and motion w, a silhouette normal satisfies u·w_radial = m w_axial. Each
   admissible generator sweeps a planar parallelogram.

Every candidate is on a translated copy of K. Conversely, an extremal point of a
convex translation sweep is on an endpoint, a swept rim, or a swept silhouette.
The minimum/maximum accepted ray parameters therefore delimit its interval.
Boundary candidates are found on the full bounded ray **before** clipping to
caller limits; clipping first would miss an interval lying entirely between the
endpoint tools. Axial caps, coplanar rays and parallel generators are covered by
endpoint/rim boundaries. Exactly transverse motion has a separate three-region
closest-segment calculation. Zero-length motion uses the stationary solver.

These statements describe real arithmetic. The implementation uses f64, stable
quadratic roots and local millimeter coordinates; it is not certified interval
arithmetic. Exact tangencies are ill-conditioned: reversal tests allow 0.2 nm
endpoint variation for intervals narrower than 1 nm, versus 0.001 nm for ordinary
analytic intervals. This test tolerance is not a universal error guarantee.
Tangential zero-length removal remains regularized away.

## Orientation approximation

XYZAC positions are wheel **centers**, not lower cap positions. A and C are
unwrapped angles; the axis is Rz(C) Rx(A) Z. Spin about this axis does not change
an axisymmetric tool. For one input segment let

- omega = sqrt(delta_A² + max(sin² A) delta_C²), in radians;
- rho = sqrt(R² + (L/2)²), measured about the wheel center;
- M be the profile's conic-offset miter factor;
- g = (1 + R + L) × 10^-8 mm be the existing practical numerical guard.

The maximum of sin² A includes interior extrema, not just endpoints. Choose
n = max(1, ceil((1+M) rho omega / (2 (tolerance - M g)))).
In each subsegment, hold the true midpoint axis, sweep its complete center
translation continuously, and offset the meridional support lines by delta+g,
where delta = rho omega/(2n). The geometric over-removal bound is

    delta + M (delta + g).

The first delta accounts for returning from the held axis to the actual tool at
the same translation time. The offset contains the maximum orientation deviation
and covers continuous motion. Unlike midpoint-pose planning, translation length
does not determine n. A long fixed-axis line needs one continuous sweep.

This bound is separate from XY sampling, finite input path chords, and floating
point conditioning. The frozen screw's input chords already differ from an ideal
helix; the solver does not silently replace that specified path with a helix.
No quaternion or general 5-axis controller interpretation is claimed.

## Storage and traversal

All sweeps, rim circles, silhouette planes and proxy poses are prepared in checked
contiguous allocations before cutting. Scratch interval capacity is reserved per
worker; queries do not allocate. An allocation/geometry failure discards the new
result, publishing no partial material state. Workers own disjoint XY rows and
merge deterministically. There is no retained-history slot reuse.

Each sweep has an exact endpoint-union AABB enclosure and a midpoint conic
rejection proxy inflated by half the translation length. The existing spatial
hierarchy groups these proxies. Proxies and group envelopes can reject work;
**only the continuous sweep** removes material. Queries skip already removed
intervals. The scalar exhaustive traversal remains an oracle for pruning.

`report.json` distinguishes `sweep_work.proxy_tests` and `sweep_work.sweep_tests`
from group-envelope tests. `poses` is a legacy count field; `prepared_kind` states
whether it counts continuous sweeps or poses/nodes. These are not voxel tests.

## Validation and scope

Tests cover analytic cylinder translations, long intervals missed by both
endpoint tools, arbitrary tilted crown sweeps, stationary/tiny/reversed/split
moves, nearly transverse and tangent rays, independent reverse-motion membership,
independent moving-tool surface/distance samples, exhaustive versus pruned
material, worker determinism, invalid input and allocation failures.
The reverse-motion oracle shares the existing static conic solver, but uses a
different construction from the swept-boundary solver. Analytic cylinder formulas
and `Tool.distance` samples provide additional checks independent of that solver.
None of this constitutes a proof of the executable or a certified Hausdorff bound.
The new algorithm is outside the existing Lean model.

Cylinder stock, one convex profiled tool, Z intervals and batch final-stock output
remain restrictions. There is no interval history, native interval animation,
STL stock, resume, fixture collision or engagement implementation in this path.
Column-solid OBJ export is derived inspection geometry, without smoothing.

See the [frozen protocol](CONTINUOUS-SWEEP-PROTOCOL.md) and
[measurements and inspected output](evidence/continuous-sweeps/README.md).
