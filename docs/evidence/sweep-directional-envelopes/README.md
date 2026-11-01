# Directional rejection envelopes for continuous sweeps

Follow-up to stage-two PR #47, based on `4c13853`. The complete cutting geometry,
motion subdivision, tolerance and input screw are unchanged. Only the enclosure
used to reject a fine sweep query changes. The default remains `fixed`.

## Enclosure

The previous stationary rejection proxy added half the translation length to
**every** normalized profile constraint. That unnecessarily widened the axial
caps of a wheel moving mostly sideways. For translation d and held tool axis a,
define da = dot(d,a) and dr = d - da*a. At the midpoint of the translation:

- axial cap offset = original offset + |da|/2;
- conical support `r - m*z <= b` expands by
  original offset × sqrt(1+m²) + |dr|/2 + |m| |da|/2.

The radial norm triangle inequality and the two extreme axial translations bound
every translated tool point. Intersecting all these support constraints gives an
outer enclosure of the full continuous sweep. A practical f64 guard is added to
the normalized supports. The enclosure only rejects candidates; it never cuts.
The existing isotropic proxies remain for group hierarchy construction.

Midpoint, radial/axial half-displacement and guard are prepared once per sweep.
No allocation is added to queries. Each worker retains disjoint rows. The scalar
continuous sweep solver remains the cutting oracle. This new enclosure is outside
the Lean model and is not a certified floating-point interval construction.

## Matched measurements

Apple M5 Max, 128 GiB RAM; Zig 0.15.2 ReleaseFast, eight workers, the unchanged
1,024-operation screw and 10 µm requested motion tolerance. One warm-up and three
measured repetitions, alternating before/after binaries at each resolution.

| XY spacing | Before median [min–max], s | After median [min–max], s | Ratio |
|---|---:|---:|---:|
| 250 µm | 0.03839 [0.03700–0.05019] | 0.03056 [0.02708–0.03553] | 1.26× |
| 100 µm | 0.26504 [0.26322–0.27008] | 0.20946 [0.20777–0.20985] | 1.27× |
| 50 µm | 1.05835 [1.01500–1.13388] | 0.86395 [0.82781–0.90384] | 1.23× |
| 25 µm | 4.05475 [3.90943–4.06841] | 3.10061 [3.08191–3.39144] | 1.31× |

At 25 µm, kernel total median is 3.10742 s and peak RSS 57,163,776 B, versus
56,606,720 B before. Fine sweep queries fall from 81,859,763 to 50,871,184
(37.9% fewer). Group-envelope and seed counts are unchanged. These are analytic
ray/sweep queries, not voxel tests or an end-to-end animation/FPS measurement.
All complete `intervals.bin` files and jobs match byte-for-byte before/after at
all four spacings, for every repetition. The motion bound remains 9.36455 µm;
the [stage-two endpoint accuracy evidence](../continuous-sweeps/README.md) applies
to these identical material states. No additional screenshot is presented as new
geometry: the actual inspected stage-two output is unchanged.

[Summary](summary.json), [all runs](runs.json.gz), [environment and binary hashes](environment.json).
The smallest runs are noisy. Compare matched binaries within this series, not
absolute times against earlier sessions. No speed ratio against Jens is inferred.

Debug and ReleaseFast each pass 103 tests, with one existing skip. The full
portable CLI suite passes, including independent endpoint distances and worker
determinism, and the Windows x86-64 ReleaseFast cross-build succeeds. Windows
execution was not performed locally. Compressed validation logs are retained.

## Fresh comparison with axis midpoint planning

A separate warm-up plus three alternating 25 µm repetitions measured `axis` at
3.97258 s median [3.71551–4.08256] and improved `sweep` at 3.12802 s
[3.05964–3.16103], a 1.27× ratio. Requested motion tolerance is 10 µm for both;
actual bounds remain 9.81437 and 9.36455 µm respectively. The approximation
policies differ, so this is **not** a byte-equivalence comparison. The previous
accuracy/material-difference report still applies. [Summary](axis-comparison-summary.json),
[raw runs](axis-comparison-runs.json.gz), [environment](axis-comparison-environment.json).

## Rejected bound propagation

Before this change, parent ray intervals were carried down the hierarchy. It
preserved output bytes but barely reduced node visits, left fine sweep counts
unchanged and worsened the 25 µm median from 4.11655 to 4.31973 s. It was removed.
[Summary](rejected-propagation-summary.json), [raw runs](rejected-propagation-runs.json.gz),
[environment](rejected-propagation-environment.json), [patch](rejected-propagation.patch).

## Validation and reproduction

The randomized boundary tests now check that each directional enclosure contains
the complete continuous-ray intersection. Twelve additional randomized overlapping
32-operation jobs match exhaustive material **byte-for-byte**. Existing independent
analytic/distance tests, invalid-input and allocation-failure tests remain active.

```sh
./zig build test
./zig build test -Doptimize=ReleaseFast
./zig build -Doptimize=ReleaseFast
python3 scripts/test-raydexels.py --out out/directional-tests-new
# Build/copy the executable at 4c13853 first, then compare it with this version:
python3 scripts/compare-raydexel-kernels.py --before /path/to/baseline-menkh --method sweep --repeat 3 --out out/directional-bench-new
```
