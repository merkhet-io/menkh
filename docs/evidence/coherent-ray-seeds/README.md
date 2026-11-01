# Neighboring-ray boundary hints

This experiment starts from the prepared-SIMD kernel merged in #50
(`70a661c`, tree equivalent to `80a9b17`). The unchanged frozen screw has
1,024 operations, 11,264 continuous translation sweeps, 10 µm requested motion
tolerance and a reported 9.36455 µm motion bound. XY spacing is a separate
sampling parameter. It is still a final-state cylindrical-stock experiment,
without native interval playback or history.

## Why this change

The baseline completed 25, 12.5 and 6.25 µm runs. Cutting time grew approximately
with the number of sampled XY rays. At 6.25 µm it produced 16,297,320 intervals,
with 680,656,896 bytes maximum observed pre-export process RSS. Repeating the
full spatial traversal for nearby rays still involves many fine sweep queries.

The new traversal records which sweep produced each retained interval endpoint.
Those sweep IDs seed the next ray in the same row. Every hinted sweep is evaluated
again at the new ray coordinates. The existing coarse seed pass and complete
hierarchy traversal still run afterward. A hint cannot certify that material is
empty, interpolate a surface, enlarge a cutter, or skip a branch on its own.
Missing/new boundaries are found by the ordinary traversal.

Rows reset their hints. This makes query counts as well as material independent
of worker partitioning. Uncut stock endpoints have a sentinel owner. Splitting,
shortening and deleting intervals update parallel endpoint-owner metadata using
the same subtraction routine. Scratch arrays are reserved before rays are
processed; there is no query-time allocation. Allocation failure discards the
new result. The scalar exhaustive traversal and an internal switch disabling
coherent hints remain available for differential tests.

This is spatial coherence in traversal, not adaptive resolution or a change to
the material representation. The orientation bound, input path, sampling policy
and fine swept-volume solver are unchanged. The new code is outside Lean's model.

## Measurement conditions

Apple M5 Max, 128 GiB RAM, Zig 0.15.2, ReleaseFast, eight CPU workers,
macOS 27.0.1. The machine is shared; unrelated CPU load varied. Runs do not overlap
local compilation or tests. Times include stock initialization and preparation
of the shared coefficient cache, but exclude export, history and viewer work.
One warm-up precedes repeated measurements. Source/binary identifiers, full
reports, material hashes and all alternatives are retained.

`baseline-scaling-*`: one warm-up plus two measured repetitions at each spacing.

| XY spacing | Cutting median (range), seconds | Maximum pre-export RSS | Final intervals |
|---|---:|---:|---:|
| 25 µm | 3.483 (3.368–3.597) | 61,456,384 B | 1,018,792 |
| 12.5 µm | 16.814 (16.635–16.993) | 185,237,504 B | 4,074,328 |
| 6.25 µm | 64.530 (63.158–65.903) | 680,656,896 B | 16,297,320 |

The first paired comparison (`first-*`, three measured repetitions) observed
4.609 → 3.279 s at 25 µm, a 1.406× median ratio. Fine sweep queries decreased from
50,871,184 to 33,284,088. Every exported interval and job byte matched.

A second variant removed coarse seeding when previous-ray hints existed.
Although its fine sweep count fell further to 30,090,353 at 25 µm, its matched
median was 3.676 s versus 3.481 s for combined seeding (about 5.6% slower).
The 100 µm comparison also favored combined seeding. This variant was rejected;
`fallback-*` retains the raw measurements and its source snapshot.

Do not multiply ratios from different sessions or compare absolute session times
as causal speedups. No matched Jens workload exists, so these numbers establish
no performance ratio against his implementation.

## Reproduction

```sh
./zig build -Doptimize=ReleaseFast
python3 scripts/benchmark-raydexels.py --methods sweep \
  --spacings 0.025 0.0125 0.00625 --repeats 2 --out out/coherent-scaling-new
python3 scripts/compare-raydexel-kernels.py --before /path/to/pre-hints/menkh \
  --method sweep --spacings 0.1 0.025 --repeat 5 --out out/coherent-comparison-new
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
```

Build the baseline from the above commit with the same compiler and SDK.
Use fresh output directories. Exported result hashes must match across baseline
and candidate; measurements alone do not validate geometry.

## Finer-resolution qualification with boundary hints

One warm-up plus two measured runs, in a separate session from the baseline
scaling runs. These are completed configurations, not extrapolated timings.

| XY spacing | Cutting median (range), seconds | Maximum pre-export RSS | Final intervals |
|---|---:|---:|---:|
| 12.5 µm | 14.076 (11.784–16.368) | 185,270,272 B | 4,074,328 |
| 6.25 µm | 55.598 (53.731–57.465) | 680,673,280 B | 16,297,320 |

Every final interval hash matches the baseline at the same resolution. These
runs establish high-resolution execution and preserved material, but their
separate-session timing differences are not an isolated optimization comparison.
`hint-scaling-*` contains full phase reports. At 6.25 µm the sampled XY domain is
1,920 × 1,920 cells spanning a 12 mm diameter blank; Z remains continuous. This
is not a 16k³ voxel run or evidence of Jens's reported surface capacity.


## Retire worker buffers during merge

Previously every worker's complete result remained allocated while the final
contiguous arrays were filled. All workers have already joined at this point.
After copying a worker's intervals, columns and counters, the merger now releases
that worker's arrays and clears its optional result so deferred cleanup cannot
free them twice. Allocation errors before merging still clean up every result.
The allocation-failure pipeline now covers the parallel preparation and merge.

With the native page allocator, untouched destination pages need not all be
resident before copying starts. Retiring copied sources reduces observed peak
RSS. Final array capacity and the initial combined address-space reservation are
unchanged; the saving is allocator/OS-dependent, not a universal bound on peak
allocated bytes.

`release-merge-*`: one warm-up and two measured repetitions. Final interval hashes
match the original pre-hint baseline at both resolutions.

| XY spacing | Cutting median (range), seconds | Maximum pre-export RSS | Final array capacity |
|---|---:|---:|---:|
| 25 µm | 3.824 (3.705–3.942) | 43,859,968 B | 20,643,712 B |
| 6.25 µm | 60.125 (59.206–61.043) | 398,852,096 B | 330,244,896 B |

At 6.25 µm this is about 41% lower observed peak RSS than the 680,673,280 bytes
measured with hints but deferred release of every worker. The later high-resolution
timing is worse than the preceding hint-only session (55.598 s). Retain that
result: these were separate runs under changing load, and the merge change is
not claimed as a cutting-speed improvement. Scratch reservations total 2,883,840
bytes for eight workers; the shared conic cache remains 4,300,520 bytes.


## Final paired comparison

Five repetitions after one warm-up for each configuration, alternating old and
new binaries. This includes both boundary hints and early worker-buffer release.
All interval and job files match byte-for-byte. Times are seconds.

| XY spacing / workers | Baseline median (range) | Final median (range) | Median ratio |
|---|---:|---:|---:|
| 100 µm / 8 | 0.301 (0.281–0.394) | 0.275 (0.235–0.327) | 1.09× |
| 25 µm / 8 | 5.087 (4.389–5.335) | 4.219 (3.396–4.446) | 1.21× |

At 25 µm, final kernel total median is 4.229 s and peak pre-export RSS is
43,859,968 bytes. Source/binary IDs and raw reports are in `final-*`. The preceding
hint-only five-repeat comparison (`confirmation-*`) observed a larger 1.42×
ratio; it is not substituted for this final 1.21× result.

An unchanged `fixed`-method regression workload at 100 µm (`fixed-regression-*`,
three measured runs after warm-up) preserved all bytes and work counts but
measured 0.740 → 0.791 s (about 7% slower). Ranges overlap: 0.720–0.787 s before,
0.709–0.903 s after. This result is retained; shared-machine timing does not
establish whether it is noise or a code regression. The optimization is not
claimed to improve every method or workload. Quiet-machine qualification of the
legacy path remains advisable before drawing broader throughput conclusions.


## Validation

Debug and ReleaseFast each pass 105 tests with one existing skip. Coverage
includes independent analytic sweeps, original versus hinted versus exhaustive
traversal, randomized overlapping jobs, exact endpoint contributors through
split/trim/delete/tangent cases, allocator failures through parallel merging,
and byte-exact material/work-count determinism across worker counts. Full saved
screw material matches the baseline at 100, 25, 12.5 and 6.25 µm.

The portable CLI suite passes all four methods, including worker determinism,
independent sampled distances and mesh edge/volume checks. Existing Lean audits,
bridge tests and deliberate failure guards pass. The Windows x86_64 ReleaseFast
cross-build succeeds; Windows execution of this new kernel awaits CI. This does
not extend the formal verification scope. Validation logs are retained here.
