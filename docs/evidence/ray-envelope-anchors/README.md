# Tighter ray-hierarchy anchors

This optimizes the existing interval kernel without changing the tool, motion
planner, tolerance, ray spacing, seed sequence or leaf evaluation order. A group
was previously enclosed around the first pose in its sorted range, often near
one end. Choose an actual pose close to the group's position/orientation center
instead. For leaves of at most eight poses, try every available anchor and
minimize the existing conservative displacement bound. For larger groups,
compare the central candidate with the original first pose. The scalar envelope
margin never exceeds the old candidate's margin; different anchors need not
produce nested enclosing solids. Each bound independently contains every pose
in its group.

The tree reuses the otherwise inactive right-child slot in a leaf for its anchor
index. Internal nodes retain their child indices and store their anchor in the
otherwise unused pose-range field. Node size and allocated capacities are
unchanged. There are no additional allocations or per-ray preparation costs.
The original scalar ray intersection and all final cutter solids are unchanged.
These rejection bounds and the Zig implementation are outside the Lean model.

## Matched measurements

Baseline source: `7cfa563bacb23be2bb26fc10168da106afe2ae82`, the original PR #46 head.
M5 Max, 128 GiB, Zig 0.15.2 ReleaseFast, eight workers, same frozen 1,024-segment
screw and `--method axis --tolerance 0.01`. One warm-up plus five measured runs
per binary/spacing, alternating order. No concurrent Menkh build, render or test
job during measurement; the workstation remained in normal use. Raw samples,
binary hashes and the exact measured source snapshot are retained.

| XY spacing | Before cutting median [min–max], s | After cutting median [min–max], s | Ratio |
|---|---:|---:|---:|
| 250 µm | 0.03988 [0.03970–0.04185] | 0.03188 [0.03150–0.03387] | 1.25× |
| 100 µm | 0.33121 [0.25213–0.33777] | 0.28406 [0.19903–0.28703] | 1.17× |
| 50 µm | 1.35656 [1.33314–1.38764] | 1.11647 [1.10606–1.13770] | 1.22× |
| 25 µm | 5.53682 [5.44585–5.70674] | 4.60302 [4.49877–4.91980] | 1.20× |

At 25 µm, kernel total median changes from 5.55884 to 4.62492 s. Peak kernel RSS
is unchanged at 50,184,192 bytes. Fine ray/pose queries fall from 359,633,569 to
282,058,105; group-envelope queries from 247,839,892 to 200,974,764. Seed queries
and cutting intervals that actually reach retained material remain unchanged.
Tree preparation does slightly more work; its cost is reported separately.

Every complete `intervals.bin` and generated `job.json` is byte-identical between
binaries at each spacing, including all warm-ups and repetitions. This is an
exact-result optimization of the chosen method, unlike the preceding switch
from fixed to axisymmetric motion preparation. It adds no motion approximation,
coarsening, smoothing or LOD. It does not change the experimental backend's lack
of history/native interval animation or establish a matched ratio against Jens.

## Validation and rejected alternatives

Debug and ReleaseFast tests pass (95/96, one existing skip). Existing random
small-grid unions agree with exhaustive evaluation. Portable tests pass for all
three methods, including worker determinism, retained core/endcaps and mesh
volume/edge checks. Separate fixed/adaptive full-path checks compare old and new
interval files at all four spacings; their record accompanies this report.

`exploratory-runs.json` retains qualification runs, not controlled performance
claims. Splitting every leaf down to a single pose reduced fine tests but slowed
the 100 µm trial from 0.237 to 0.503 s. A shared 8×8 XY tile prepass reduced some
hierarchy queries but added preparation work and about 0.98 MB worker scratch
at 25 µm; its 5.479 s versus 5.481 s trial showed no useful gain. Both were removed.
The rejected tile patch is preserved for audit. Early anchor prototypes swapped
leaf poses; the final version explicitly preserves their order.

## Reproduce

Build the baseline commit in a separate checkout with Zig 0.15.2 ReleaseFast and
pass its executable as `--before`. Build the current checkout, then run:

```sh
./zig build -Doptimize=ReleaseFast
python3 scripts/compare-raydexel-kernels.py --before /path/to/baseline/menkh --method axis --repeat 5 --out out/anchor-comparison-new
./zig build test
./zig build test -Doptimize=ReleaseFast
python3 scripts/test-raydexels.py --out out/anchor-tests-new
```

The comparison fails if any material byte or generated job changes. Windows uses
`menkh.exe`; the script selects the current executable suffix automatically.
An unchanged-output optimization does not require a new illustrative screenshot:
the actual result remains the one inspected in the preceding experiment.

Windows x64 ReleaseFast cross-build and the existing Lean/audit/bridge suite also
passed. These checks do not formally verify the new spatial rejection algorithm.
