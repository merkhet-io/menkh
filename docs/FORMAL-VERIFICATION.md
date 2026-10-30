# Formal verification: Lean and Veil

This is an initial verification layer, not certification of the Zig executable.
It contains **23 named Lean results** about discrete material and real-arithmetic
geometry, plus **50 Veil verification conditions** for two abstract transition
systems. The proofs are checked by Lean; their relationship to production Zig
is reviewed and tested, not formally proved.

## Run it

Requires an existing `elan` installation, Python 3, and the project's Zig setup.
No verification dependency is linked into the simulator or viewer.

```sh
# First use: download missing pinned toolchains into .tools/elan, and local packages.
./scripts/bootstrap-formal.sh
# Geometry/discrete proofs, axiom audit, executable corpus, both Zig build modes:
./scripts/verify-formal.sh
# Veil transition proofs, axiom audit, and negative controls:
./scripts/verify-veil.sh
# Existing tests remain independent of Lean:
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
```

`formal-lake.sh` selects an already installed matching toolchain (repository-local
first). It fails with an explicit setup instruction if missing. It does not
silently install a global toolchain. Dependencies and both Lake manifests are
pinned; `.lake` build/cache directories are ignored.

- Mathematical model: Lean **4.24.0**, mathlib commit
  `f897ebcf72cd16f89ab4577d0c826cd14afaafc7` (v4.24.0).
- Transition models: Lean **4.32.0**, Veil commit
  `eb458cb602d3cf9a19d8f5d8af21edcf27775c8e` (2.0 pre-release).
- Engine: Zig **0.15.2**. Local validation: Apple M5 Max, macOS, native aarch64.

The separate Lake projects deliberately isolate Veil's newer toolchain and SMT
libraries from the stable mathematical project.

## What the Lean statements establish

See [`formal/Menkh`](../formal/Menkh) and the required-name list in
[`formal/Audit.lean`](../formal/Audit.lean).

| Area | Named results | Exact scope |
|---|---:|---|
| Discrete occupancy | 10 | Per-axis block/local round trip; unique XY bit index; logical boundary mask; full-to-mixed decoding; actual `BitVec 64` subtraction; finite population sum; subtraction semantics, monotonicity, idempotence; conditional accelerated/scalar equivalence |
| Cylinder geometry | 9 | Clamp membership; radial minimum including zero radial velocity; continuous radial sweep; both axial-velocity signs; constant-Z capsule product; interval-based finite-cylinder sweep; complete sign-branch `flatContains_exact` |
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

## Why Veil is in the process

[Veil](https://veil.dev/docs/) is a Lean framework for transition-system safety
properties, with SMT automation and optional Lean proof reconstruction. It is a
fit for lifecycle invariants, while mathlib handles continuous geometry.
Its upstream version is a pre-release, pinned here to avoid unreviewed upgrades.

[`formal/veil/Cutting.lean`](../formal/veil/Cutting.lean) contains two models:

1. **Cutting**: arbitrary voxel and operation types, immutable initial stock and
   cutter membership, mutable material, a single reversible checkpoint, cut,
   undo, redo, and rejected-operation transitions. Six invariants establish
   stock containment, snapshot containment, removed-material provenance,
   before/after partition, disjoint remaining/removed sets, and exact occupancy
   restoration after undo. Five stages (initializer plus four actions), each
   with six invariant conditions and a nonthrowing condition: **35 proofs**.
2. **Pool**: arbitrary blocks, slots and payloads, live ownership and history
   references. Bind, release, capture and checkpoint transitions preserve unique
   ownership and the values of retained snapshots. Reuse is forbidden while a
   slot is live or remembered. Five stages with two invariants and nonthrowing
   conditions: **15 proofs**.

The pool model specifies a safe reuse policy. It does not change the Zig allocator
or prove its current history/compaction implementation. The cutting model retains
one checkpoint, not the full on-disk history sequence. A reject transition is
explicitly a no-op; this does not prove actual Zig allocation-failure atomicity.
Undo can restore material, so cut monotonicity must not be claimed for all history
transitions. Geometry is an uninterpreted relation in Veil, not an assumed
geometrically correct cutter.

## Trust and CI gates

`.github/workflows/verification.yml` runs on pull requests, pushes to main and
`codex/**`, and manual dispatch:

- **macOS Apple Silicon**: original Debug/ReleaseFast tests, Lean model build,
  axiom audit, oracle generation and Zig differential tests in both modes.
- **Linux**: Veil build with SMT proof reconstruction, audit of all required
  generated declarations, and deliberate-bug rejection checks. This runs only
  the verification models; the simulator's product scope remains macOS.

Both audits permit only `propext`, `Classical.choice`, and `Quot.sound`. They check
transitive proof dependencies and fail on missing required results. This excludes
`sorryAx`, trusted solver shortcuts, native-decision axioms and custom axioms from
the audited theorems. Veil explicitly sets `veil.smt.trust false` and
`veil.violationIsError true`, exports the results with `#gen_theorems`, then checks
that all 50 expected proof declarations exist. Auxiliary/generated theorems are
also audited; their number is not presented as extra principal results.

Three negative controls must fail for the intended mathematical reason:

- Replace word subtraction AND with OR.
- Make cutting add occupied cells.
- Remove the guard preventing reuse of history-retained pool slots.

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
  zero axial velocities. These are vertical-tool cases, not tilted-frame tests.

The subtraction fixture calls the proved bit operation. The rational geometry
oracle is a separately executable transcription; its embedding into the real
model is not proved. Its exact arithmetic can expose `f64` discrepancies on this
finite corpus, but cannot establish a global rounding bound. Existing engine
randomized and tilted-tool tests remain relevant independent evidence.

Local validation passed all 23 named mathematical results, all 50 Veil conditions,
the axiom audits, all 20,480 bridge records in both Zig modes, and the original
35 test groups in both modes. Negative controls rejected all three injected bugs.
This work introduces no runtime engine changes or performance claims.

Still outside this proof boundary: IEEE-754 rounding and compiler semantics;
all classifier instantiations; tool-frame normalization; ball/bull/taper sweeps
and motion-error bounds; mesh import; multi-checkpoint binary history and state
files; memory safety/overflow; collision clearance; exported meshes; rendering.
A model proof is not a 25 µm surface-error guarantee or industrial certification.
