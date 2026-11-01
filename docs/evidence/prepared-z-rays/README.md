# Prepared world-Z conic rejection experiment

This follow-up starts from recovery commit `1b6ee111d19ab60a1105271de24cea9881b6fd05`
(the tree of the validated directional-enclosure stage). It does not include the
rejected ray-union boundary-search experiment. PR #49 is left for the owner to merge.

## Measurement conditions

Apple M5 Max, 128 GiB, 18 logical CPUs; macOS 27.0.1; Zig 0.15.2,
ReleaseFast, eight workers unless explicitly recorded otherwise. The unchanged
frozen screw uses 1,024 operations, 11,264 continuous translation sweeps and a
9.36455 µm conservative motion bound at a requested 10 µm tolerance. Ray spacing
is independent of that bound. Cutting times include stock initialization and
preparing the new coefficient cache; export and independent accuracy checks are
outside this phase.

The machine was shared with active VM and database processes. Alternating runs,
one warm-up per configuration and repeated measured runs reduce ordering bias;
they do not remove contention or establish isolated hardware throughput. Retain
all ranges and do not compare absolute times with earlier quiet-machine runs.
Every run verifies byte-identical `intervals.bin` and `job.json` against the
paired executable. Binary hashes and complete reports are retained.

## Profiling and implementation

`baseline-sample.txt.gz` is a one-second native macOS stack sample of the
unmodified sweep kernel. Sampling found substantial conic/quadratic and sweep
work, not an allocation/export bottleneck. Inlined functions can be charged to
callers; stack counts are not precise function-time percentages. The sampled
run is not a timing benchmark.

The new immutable cache prepares world-Z direction terms for group and per-sweep
rejection enclosures once before starting workers. Four conic sides are evaluated
with `@Vector(4, f64)`; clipping and retained-material rejection retain the scalar
side order. Padding lanes do not contribute. Negative-discriminant/linear lanes
can calculate unused roots but never use them to clip material. Floating-point
fast-math is not enabled. The finite-tool swept intersection and subdivision
policy are unchanged. No per-ray allocation is introduced. Shared cache bytes
and preparation time are explicit report fields; preparation is included in cut
time. The cache is freed after all workers and merging complete. Allocation
failure publishes no result.

This implementation is outside the Lean model. Differential equality tests
validate this implementation relationship empirically, not formally.

## Retained alternatives

- `scalar-*`: prepared scalar coefficients. Four-resolution median speed ratios
  were 1.055, 0.981, 0.990 and 1.008. No useful consistent gain.
- `simd-roots-*`: full vector quadratic calculation. Initial paired ratios were
  1.084, 1.159, 1.276 and 1.113; substantial timing variation requires caution.
- `simd-coefficients-*`: vector coefficients followed by the original scalar
  quadratic solver. Compared directly with full SIMD, this was slower. Five
  repetitions at 100 and 25 µm are retained, including unfavorable measurements.

Compressed prototype sources preserve the alternatives. Initial source-diff
hashes exclude untracked files, so the archived prototype is required alongside
the integration patch; follow-up benchmark metadata now hashes source files,
including untracked source, explicitly.

## Reproduction

```sh
./zig build -Doptimize=ReleaseFast
python3 scripts/compare-raydexel-kernels.py --before /path/to/baseline/menkh \
  --method sweep --repeat 5 --out out/prepared-rays-comparison
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
```

The baseline executable must be built from the above recovery commit using the
same compiler, SDK and build mode. This is an experimental final-stock interval
kernel, not the voxel/history/viewer engine. No claim about Jens's throughput,
interactive FPS or general production machining follows from this measurement.

## Follow-up measurements

Five repetitions after one warm-up for each binary/configuration. Times are
seconds; parentheses contain min–max. These are observations under shared-machine
load, not guaranteed speedups. Geometry query counts are identical.

| Spacing / workers | Scalar baseline median (range) | Prepared SIMD median (range) | Median ratio |
|---|---:|---:|---:|
| 100 µm / 8 | 0.2508 (0.1673–0.2869) | 0.2406 (0.1446–0.2522) | 1.04× |
| 25 µm / 8 | 4.7297 (4.4503–7.4983) | 3.8063 (3.4471–5.0754) | 1.24× |
| 100 µm / 1 | 1.4844 (1.3289–1.5701) | 1.2098 (1.0917–1.5542) | 1.23× |

At 25 µm, maximum observed pre-export process RSS was 57,180,160 bytes for
baseline and 61,456,384 bytes with the cache. The shared cache contains 4,300,520
allocated bytes; per-worker scratch remains 1,441,920 bytes summed across eight
workers. Total-kernel medians were 4.7379 and 3.8147 seconds, respectively.
`final-*` and `one-worker-*` contain these raw reports and source/binary hashes.
The earlier four-resolution run is retained rather than replaced by the better
follow-up result.

## Validation scope

- Debug and ReleaseFast: 104 tests passed, one existing skip.
- Differential group/sweep proxy endpoint bits, randomized overlapping jobs,
  exhaustive traversal, complete output bytes and work counters agree.
- One-to-five conic sides cover partial vector groups, axis-aligned and nearly
  transverse cases; existing independent finite-cylinder/sweep geometry tests
  still run. These differential proxy tests do not independently prove the
  underlying tool model.
- Allocation-failure injection covers cache construction/cleanup. One/four-worker
  complete material results match exactly.
- Portable CLI checks pass for fixed, adaptive, axis and sweep methods, including
  retained core/end caps, export edge coverage, invalid arguments and independent
  sampled sweep distances.
- Existing Lean audits, executable bridge and deliberately broken proof guards
  pass. No additional formal-verification claim is made for this SIMD code.

`integration.patch.gz` plus the selected compressed prototype reconstructs each
prepared-ray variant's integration relative to the baseline. Final source hashes
are also recorded; prototype timing runs preceded the additional lane-tail test.

The x86_64 Windows ReleaseFast cross-build also succeeds. Windows execution and
Windows performance were not measured on this macOS host.
