# CPU performance: first optimization pass

Measured on Apple M5 Max (18 logical CPUs), macOS 27.0.1, Zig 0.15.2,
ReleaseFast. Material removal still uses **one CPU worker**. Geometry remains
`f64` with continuous sweeps and the existing occupancy/tolerance semantics.
No GPU cutting or discrete-pose substitution was introduced.

## End-to-end pocket demo

The same 325-segment pocket job, stock, tool assembly and history/export settings
were used before and after. Each repetition starts with fresh stock in a fresh
process. One warm-up is excluded. There are seven measured repetitions at 100 µm
and three at each other spacing. Raw samples, min/max, executable/job hashes and
memory measurements are in [`benchmarks/performance`](../benchmarks/performance).

| Spacing | Baseline cutting | Optimized cutting | Baseline CLI wall | Optimized CLI wall |
|---|---:|---:|---:|---:|
| 250 µm | 14.94 ms | 1.24 ms | 50.41 ms | 32.99 ms |
| 100 µm | 78.41 ms | 4.73 ms | 217.62 ms | 62.19 ms |
| 50 µm | 367.46 ms | 18.56 ms | 1,151.60 ms | 193.71 ms |
| 25 µm | 2,123.62 ms | 94.50 ms | 7,064.22 ms | 298.25 ms |

These are medians. At 100 µm, cutting ranged from 77.94–79.09 ms before and
4.50–4.80 ms after; CLI wall time ranged from 214.27–223.14 ms and 60.29–64.22 ms.
At 25 µm, cutting ranged from 2,120.87–2,144.88 ms and 93.72–95.07 ms; CLI wall
time ranged from 7,035.80–7,098.67 ms and 296.84–301.88 ms.

The 25 µm case starts with **221,184,000 occupied voxels** and ends with
170,711,351. It disables OBJ mesh generation in both versions; the other three
cases include it. Wall time includes process startup, cutting, collision checks,
history, PPM, checkpoint and report exports. It excludes rendering, video encoding
and viewer upload. File writes use the OS cache; these are not fsync/durable-I/O
measurements. Do not compare different table rows as if their output settings
were identical.

Final checkpoints match the baseline **byte-for-byte at all four resolutions**.
All 328 binary history/checkpoint files also match at 100 and 25 µm. This is a
performance change to the same simulated result.

## What changed and why

A four-second sample of the 25 µm baseline showed substantial collision block
traversal and repeated finite-cylinder classification. The raw sampling report
is retained as `baseline-profile.txt`.

- Canonical +Z flat tools get a tight swept-cylinder bounding box. Other tools
  and orientations keep the existing conservative general bound. The scalar
  cutting reference retains the original broad bounding box.
- Collision checks traverse only the intersecting block range, reuse occupancy
  masks, count bits with popcount, and obtain exact occupied-center extrema from
  the eight block words. A simple full-grid scalar collision oracle is retained.
- Constant-Z +Z flat sweeps evaluate the XY capsule once per occupied column and
  reuse it across axial layers. The classifier uses four XY corners plus the
  axial interval, with conservative exclusion and the existing numerical margins.
- Dense XY rows use `@Vector(8, f64)`; very sparse masks retain scalar evaluation.
  This is native CPU SIMD, not AVX-512 on Apple hardware. Coordinates are computed
  with the original expression order rather than incremental additions.
- The preflight caches one byte of classification per candidate-range block for
  the write pass. Capacity is reserved before mutation, reused between operations
  and freed with `Changes`. History slot allocation/order is unchanged.

The separate scalar-specialization measurements preceded SIMD. At 100 µm their
cut median was 6.87 ms; the first SIMD variant measured 5.76 ms. At 25 µm those
medians were 121.77 ms and 116.53 ms. The final classifier/cache changes bring them
to 4.73/94.50 ms. Most of the gain is avoiding repeated work and unnecessary
traversal, not SIMD alone.

The pocket shank and holder remain above the stock. Their checks fall from about
80.13 ms to 0.079 ms at 100 µm, and 4.68 s to 0.201 ms at 25 µm, because bounds can
reject them immediately. **This is not a thousandfold improvement in voxel-test
arithmetic**, nor evidence of that speedup for engaged/colliding holders.

Allocated classification scratch peaks at 48, 384, 2,002 and 14,850 bytes for the
four pocket sizes. At 100 µm grid descriptors+pool capacity remain 288,576 bytes;
measured process peak RSS is about 9.93 MB. At 25 µm descriptors+pool capacity are
9,011,968 bytes and peak RSS about 27.0 MB. Scratch is additional and reported as
`cut_scratch_capacity_bytes` in job reports. It is proportional to the candidate
block box, not the number of voxels, but can grow for large-world operations.

## Predicate throughput, separately from machining

`./zig build kernel-bench -Doptimize=ReleaseFast` measures every point against one
stationary finite cylinder or one continuous XY finite-cylinder sweep. It uses
the same SIMD radial kernel as cutting masks, closed expanded boundaries, `f64`,
16 tool placements, and 65,536 points in a 1.5 MiB structure-of-arrays buffer.
Each repetition performs 268,435,456 tests. There is no occupancy culling, material
update, history, surface generation or rendering in this benchmark.

Five measured repetitions follow a warm-up. Thread creation/join is included.
Every SIMD lane is first compared with the scalar predicate, and every timed
checksum is checked against the expected hit count. Workers receive disjoint
point ranges. Default OS scheduling is used; affinity, clock and thermal state
are not controlled.

| Predicate | Scalar, 1 worker | SIMD, 1 worker | SIMD, 8 workers |
|---|---:|---:|---:|
| Stationary finite cylinder | 0.226 billion/s | 1.241 billion/s | 9.174 billion/s |
| Continuous XY sweep | 0.228 billion/s | 0.864 billion/s | 6.963 billion/s |

Eight-worker SIMD ranges were 8.085–10.017 billion/s and 6.950–6.999 billion/s.
All raw measurements, including eight-worker scalar results, are in
`predicate-kernel.json`. Zig's detected CPU model string is `apple_m1` despite
the actual M5 Max host; both baseline and optimized builds use the same installed
compiler and native target selection. These are cache-resident predicate rates,
not streaming-memory or whole-job throughput. The eight-worker path is currently
**only in the diagnostic benchmark**, not the material-update engine.

Jens reports up to 20 billion voxel-versus-cutting-position tests/s using about
eight Ryzen threads and AVX-512. Without his kernel, input geometry, arithmetic
precision, data layout and accuracy criterion, this is a reference target rather
than an apples-to-apples comparison. The stationary row is closer to his stated
unit of work; the continuous-sweep row does more work per test. We have not
established parity or a reliable cross-implementation speed ratio. Neither
predicate number measures creation of five billion surface voxels.

## Broader workloads and validation

The ten-scenario suite still agrees voxel-for-voxel with scalar subtraction,
including ball finishing, thin walls, tilted tools, overlapping cuts, sparse
stock, STL cavities/concavity, turning envelopes and helices. Binary resume and
compacted resume, collision reports and mesh orientation/closure checks pass.
Non-grid-aligned sphere accuracy checks at 250/100/50/25 µm were also rerun.

The full **4096³ drill** (one warm-up, three repetitions per version) improved
from 4.627 s median total generation to 4.230 s, about 1.09×. Its final material
count remains 1,333,399,870. Peak RSS increased from 647.66 MB to 648.41 MB, including
classification scratch. This demo uses capsule/half-space operations, so it does
not receive the flat-tool specialization. Ball finishing and helices were roughly
unchanged; the small tilted test measured 0.184 vs 0.186 ms cutting. Broad raw
samples are retained in `suite-comparison.json`, not replaced by the favorable
pocket result.

The original 25 µm groove benchmark also passes: its existing specialized fast
path measured 7.21 ms median cutting. There is no claimed improvement to that path.
39 test groups pass in Debug and ReleaseFast, including new mask, tangent,
collision-extrema and allocation-failure comparisons. The 34 Lean model results,
axiom audits, negative controls and 20,480-record bridge pass; eligible rational
sweep records now exercise SIMD too. These tests do not constitute a proof of
floating-point implementation equivalence for all possible inputs.

## Reproduce

```sh
./zig build -Doptimize=ReleaseFast
python3 scripts/pocket-demo.py
python3 scripts/benchmark-performance.py --exe zig-out/bin/menkh \
  --job out/pocket-demo/job.json --out out/performance/current-100.json
python3 scripts/benchmark-performance.py --exe zig-out/bin/menkh \
  --job out/pocket-demo/job.json --voxel .025 --no-mesh \
  --out out/performance/current-25.json --repeats 3
./zig build kernel-bench -Doptimize=ReleaseFast > out/performance/kernel.json
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
./scripts/verify-formal.sh
python3 scripts/validate-engine.py
python3 scripts/benchmark-engine.py --out out/performance/suite --repeats 3
./scripts/benchmark-4096.sh
```

The saved baseline executable was built at `99a038a`, whose source tree is
identical to merged main `14720bc` before this change. To reproduce it without
replacing the current checkout or installing another global toolchain:

```sh
git worktree add --detach out/performance/baseline-src 14720bc
./zig build --build-file out/performance/baseline-src/build.zig \
  --prefix "$PWD/out/performance/baseline-bin" -Doptimize=ReleaseFast
python3 scripts/benchmark-performance.py \
  --exe out/performance/baseline-bin/bin/menkh --job out/pocket-demo/job.json \
  --out out/performance/baseline-100.json
```

Measurement files identify the parent commit and dirty checkout because the
optimized executable was measured before committing the change. Executable/job
hashes identify the exact artifacts; `validation.json` records source fingerprints.
The broad suite's source fingerprints describe the checkout, which can differ
from a supplied `--exe`; the executable hash identifies that binary.

Remaining performance work includes parallel material updates with amortized
worker startup, general tilted/non-flat kernels, and incremental surface/export
work. At 100 µm surface generation alone still takes about 19.3 ms, now more than
four times the cutting phase. Those costs should remain separate from predicate
throughput when choosing the next optimization.
