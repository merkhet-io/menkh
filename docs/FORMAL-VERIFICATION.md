# Formal verification with Lean

This is an initial verification layer, not certification of the Zig executable.
It contains **34 named Lean results** about discrete material and real-arithmetic
geometry and abstract history/pool contracts. The proofs are checked by Lean; their relationship to production Zig
is reviewed and tested, not formally proved.

## Run it

Requires an existing `elan` installation, Python 3, and the project's Zig setup.
No verification dependency is linked into the simulator or viewer.

```sh
# First use: download missing pinned toolchain into .tools/elan, and local packages.
./scripts/bootstrap-formal.sh
# Geometry/discrete proofs, axiom audit, executable corpus, both Zig build modes:
./scripts/verify-formal.sh
# Existing tests remain independent of Lean:
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
```

`formal-lake.sh` selects an already installed matching toolchain (repository-local
first). It fails with an explicit setup instruction if missing. It does not
silently install a global toolchain. Dependencies and the Lake manifest are
pinned; `.lake` build/cache directories are ignored.

- Mathematical model: Lean **4.24.0**, mathlib commit
  `f897ebcf72cd16f89ab4577d0c826cd14afaafc7` (v4.24.0).
- Engine: Zig **0.15.2**. Local validation: Apple M5 Max, macOS, native aarch64.

There is one Lean/mathlib project. No separate transition-system framework,
SMT solver, Node dependency or second Lean version is required.

## What the Lean statements establish

See [`formal/Menkh`](../formal/Menkh) and the required-name list in
[`formal/Audit.lean`](../formal/Audit.lean).

| Area | Named results | Exact scope |
|---|---:|---|
| Discrete occupancy | 10 | Per-axis block/local round trip; unique XY bit index; logical boundary mask; full-to-mixed decoding; actual `BitVec 64` subtraction; finite population sum; subtraction semantics, monotonicity, idempotence; conditional accelerated/scalar equivalence |
| Cylinder geometry | 9 | Clamp membership; radial minimum including zero radial velocity; continuous radial sweep; both axial-velocity signs; constant-Z capsule product; interval-based finite-cylinder sweep; complete sign-branch `flatContains_exact` |
| History and pool | 11 | Removed-material provenance, partition/disjointness, undo/redo, stock containment, initial pool validity, preservation under bind/release/capture/checkpoint |
| Block reasoning | 4 | Padded real-arithmetic candidate range; convex corner inclusion; one-sided distance bounds for exclusion and inclusion |

`flatContains_exact` equates the real-arithmetic predicate with existence of a
continuous time `t` in `[0,1]` at which the finite cylinder contains the point.
It does not replace a finite cylinder by a sphere or capsule. Coordinates are
already in a local orthonormal tool frame. The model uses explicit lower/upper
axial limits and a squared radial threshold; callers supply physically valid
limits/radius. It sorts cap times by velocity sign. Zig uses min/max of the two
cap times. Both axial sign proofs and the differential tests cover this
correspondence, but there is no mechanically checked translation of Zig.

Tangencies are closed inequalities. The real proofs have no implicit epsilon;
explicitly expanded tool limits can be substituted. The rational test oracle
uses the engine's `1e-10 mm` expansion, radius 2 mm and length 3 mm.

**Conditional statements matter:** `accelerated_eq_scalar` requires correct
candidate inclusion and inside/outside classifications. `corners_inside`
requires convexity of the cut set. The distance lemmas require the stated
one-sided distance bound. These are useful composition results; they do not
prove that every current `Shape.classify` branch meets those assumptions.
Likewise, the candidate theorem proves the padded real bounds, not floating-point
floor/ceil conversion, grid clamping, block division, or machine-integer overflow.
The logical boundary mask is tested against `Grid.validBits`; its Zig packing loop
is not formally derived. `population_exact` counts model bits, not a proof about
Apple's popcount instruction.

Thus the originally proposed twelve principal obligations are **partially
covered**, not twelve completed end-to-end implementation proofs. The strongest
completed geometric result is the finite-cylinder predicate over real arithmetic.

## History and pool contracts in ordinary Lean

[`formal/Menkh/History.lean`](../formal/Menkh/History.lean) proves:

- Removed material was present before the cut.
- Remaining and removed material form a disjoint partition of the original.
- Restoring the removed set recovers the original occupancy; reapplying the cut
  recovers the post-cut occupancy.
- Cutting preserves containment in initial stock.
- Pool initialization is valid, and bind/release/capture/checkpoint transitions
  preserve exclusive slot ownership and remembered payload values.

Pool binding requires that the replacement slot is neither live nor retained
by history. An explicit checkpoint forgets retained snapshots. These are
mathematical contracts for a safe reuse policy; they do not change the Zig
allocator or prove its implementation. The history proof concerns an occupancy
delta, not the full on-disk history sequence, descriptor bytes or allocation
failure. Undo can restore material, so monotonicity applies to cuts, not to all
history transitions.

## Trust and CI gates

`.github/workflows/verification.yml` runs on pull requests, pushes to main and
`codex/**`, and manual dispatch. The macOS Apple Silicon job runs the original
Debug/ReleaseFast tests, Lean model build, axiom audit, oracle generation and Zig
differential tests in both modes. The simulator's product scope remains macOS.

The audit permits only `propext`, `Classical.choice`, and `Quot.sound`. It checks
transitive proof dependencies and fails on missing required results. This excludes
`sorryAx`, native-decision axioms and custom axioms from the audited theorems.
Auxiliary/generated theorems are also audited; their number is not presented as
extra principal results.

Three negative controls must fail for the intended proof obligation:

- Replace word subtraction AND with OR.
- Replace undo's occupancy union with intersection.
- Make pool binding overwrite every payload, including unrelated retained slots.

These checks use temporary copies in `out/`, leave the source intact, and reject
unexpected infrastructure failures instead of counting them as successful tests.
They are regression guards, not an independent proof checker. Lean's kernel,
imports/toolchain and the adequacy of the formal statements remain trust boundaries.

## Differential evidence and limits

`formal/Oracle.lean` generates **20,480 deterministic records** consumed by
`src/formal_bridge.zig`:

- 4,096 boundary-mask word records: all 512 nonempty 8³ edge extents, eight words each.
- 4,096 word-subtraction records, checking production bit storage/statistics too.
- 8,192 block/local address records.
- 4,096 exact-rational sweep evaluations with varying point and translation
  coordinates on a quarter-millimetre lattice, including positive, negative and
  zero axial velocities. Eligible constant-Z and pure vertical records also exercise the SIMD batch predicate. These are vertical-tool cases, not tilted-frame tests.

The subtraction fixture calls the proved bit operation. The rational geometry
oracle is a separately executable transcription; its embedding into the real
model is not proved. Its exact arithmetic can expose `f64` discrepancies on this
finite corpus, but cannot establish a global rounding bound. Existing engine
randomized and tilted-tool tests remain relevant independent evidence.

Local validation passed all 34 named mathematical results,
the axiom audits, all 20,480 bridge records in both Zig modes, and the original
41 test groups in both modes. Negative controls rejected all three injected bugs.
This work introduces no runtime engine changes or performance claims.

Still outside this proof boundary: IEEE-754 rounding and compiler semantics;
all classifier instantiations; tool-frame normalization; ball/bull/taper sweeps
and motion-error bounds; mesh import; multi-checkpoint binary history and state
files; memory safety/overflow; collision clearance; exported meshes; rendering.
A model proof is not a 25 µm surface-error guarantee or industrial certification.
