# Product roadmap: a dependable geometric cutting SDK

Updated 2026-10-30. This is an ordered product plan with release gates, not a claim
of ModuleWorks parity or a calendar estimate. Numerical targets below are proposed
acceptance criteria unless explicitly linked to measured results.

## Product boundary and first useful release

Menkh consumes stock, tool assemblies and motion, updates authoritative voxel
material, and explains geometric engagement, excess, missing material and contact.
The first supported product should be **fixed-orientation 3-axis milling on macOS
Apple Silicon**, with a headless Zig engine and native Swift/Metal inspection.
Existing Windows CLI/viewer work remains supported at its documented level; it is
not a reason to add another rendering backend in this roadmap.

The first users are developers integrating geometric verification into CAM or
manufacturing tools, and engineers inspecting supplied toolpaths. Toolpath
creation, machine kinematics, controller emulation and thermomechanics remain
separate products or integrations. No unsafe-path avoidance or machine-cycle-time
promise follows from a geometric contact report.

ModuleWorks publicly describes milling, turning and mill-turn stock verification,
SDK integration, toolpath analysis and dimensional inspection through Smart Measure.
Its broader simulation portfolio also includes machine simulation and multi-axis
applications. These public descriptions establish the reference category; they do
not provide a comparable performance or accuracy benchmark for Menkh.
Sources: [Simulation SDK](https://www.moduleworks.com/software-components/simulation-portfolio/simulation-sdk/),
[simulation portfolio](https://www.moduleworks.com/software-components/simulation/)
(accessed 2026-10-30). No proprietary APIs, formats, implementation or assets are
being copied.

## Starting point: implemented and tested, not yet industrially qualified

| Capability | Evidence and boundary |
|---|---|
| Imported stock/target finishing | Frozen 24 × 16 mm insert, 5,199 ball-end segments, 25 µm; repeated timings and exact saved-state/history comparisons |
| Geometry robustness | Shared-topology intersection fix accepts all 16 transformed fixtures; genuine foldovers, crossings and intersecting shells still rejected |
| Continuous motion | Exact flat sweeps; error-controlled sampled/dilated complete ball tools; independent hemisphere-plus-finite-flute interval oracle |
| Contact inspection | Separate cutter/fixture, shank and holder reports; explicit separated/contact/unresolved/not-checked states; full-resolution clamp example |
| State and visualization | Checkpoint/compacted resume, byte-exact history replay, direct voxel rendering, sections and target comparison |
| Verification | Zig tests, independent geometric oracles and existing Lean model checks; no proof of the complete executable |
| Broader machining | Some tool families, fixed tilt and restricted turning exist; simultaneous orientation-changing sweeps and production mill-turn remain unsupported |

See [current capability matrix](CAPABILITIES.md) and
[completed robustness work](MILLING-ROBUSTNESS.md). The procedural fixtures are
useful engineering tests, **not customer qualification**. That distinction is the
first gap this roadmap addresses.

## Ordered milestones

### 1. Qualify a narrowly defined production corpus

**User outcome:** an engineer can import a declared class of real parts and run a
supplied 3-axis path without investigating unexplained geometry failures.

Obtain at least 20 licensed or explicitly supplied production-style stock/target
pairs across molds, brackets/plates, cavities and thin-wall parts. Include several
parts above 100 mm extent, multiple disconnected components, transformed geometry,
small holes and difficult tessellation. Record provenance, units, tessellation
settings, expected topology and why each path represents a plausible setup.
External customer data is still needed; do not relabel generated fixtures as such.

Freeze each job before optimizing. Run 250, 100, 50 and 25 µm where feasible,
separately vary motion tolerance, and retain failures. Establish a declared size,
triangle-count, motion-count and memory envelope from these runs. A case that
exceeds the budget must be reported as unsupported/resource-limited, never silently
coarsened or removed from the corpus.

**Exit gate:** every case in the proposed supported envelope either completes all
specified checks or rejects a demonstrably invalid/unsupported input with an
explanation. No unexplained rejection of a known-valid case; no accepted known
self-intersection/nonwatertight corruption; optimized/reference occupancy equality
on all small-grid reductions; independent geometry checks for constructed cases.
All stock/target/fixture coordinate transforms must be exercised. Persist and
reproduce every discovered bug as a regression fixture.

**Dependency:** rights to external geometry and independently prepared paths. This
milestone is not complete simply because more synthetic cases pass.

### 2. Make inspection and accuracy actionable

**Delivered increment:** [the defect inspector](DEFECT-INSPECTOR.md) now groups
exact raster differences and connects collision events to camera focus, sections
and history selection. This does not complete the local-distance, external-part
qualification or time-resolved clearance gates below.

**User outcome:** a user can locate and interpret a potential gouge, excess region
or assembly contact without mistaking raster or motion uncertainty for certainty.

Add bidirectional sampled 3D surface-distance reports against target meshes, using
an independently validated nearest-triangle structure and voxel-boundary queries.
Separate target tessellation, intentional allowance/scallops, motion approximation,
occupancy and display reconstruction. Report maximum and percentile errors by
region, including steep walls, holes and thin features; explicitly flag lost
features. Sampled distances must remain labeled as samples, not Hausdorff bounds.

Validate contact against evolving stock within long operations; distinguish the
current pre-operation-stock conservatism from actual time-resolved contact.
Extend the viewer with an operation-linked contact/defect list, selection of the
reported world-space region, and visible distinctions among represented contact,
unresolved voxel contact and separation. Preserve raw voxel inspection and keep
lighting smoothing separate from geometry. Add dimension measurements only with a
clear definition of whether they refer to CAD input, a fitted estimate or voxel
faces. Local clearance bounds must name both the stock and swept-tool models.

**Exit gate:** independently seeded defects and tangencies are found and localized;
no false-clear result in the declared test suite; a second engineer can inspect and
explain each defect using the exported report/viewer. Validate surface distances
against spheres, inclined planes and finite-tool sweeps in both directions. This
gate does not assert physical machine clearance or universal 25 µm accuracy.

**Dependency:** milestone 1 corpus and a written numerical/clearance contract.

### 3. Scale the validated engine and long-job storage

**User outcome:** larger parts and long paths finish predictably, stay within a
published resource envelope and remain inspectable while processing.

Continue profiling ball-distance work before changing sweep semantics. Evaluate
analytic decomposition or bounded minimization only against the retained oracle
and explicit motion error. Then evaluate CPU workers over disjoint blocks with
preassigned pool slots and deterministic operation order. Preserve a one-worker
reference and measure 1/2/4/8 workers where hardware permits.

Use the corpus to decide whether sparse top-level tiling actually helps mutable
material and history. Measure both sparse and heavily occupied scenes before
changing storage. Add a bounded checkpoint/history policy with documented seek and
retention behavior. Support cancellation at atomic operation boundaries and show
progress without coupling rendering to cutting.

**Exit gate:** a frozen 100,000-segment stress job completes uninterrupted and through
multiple checkpoint/resume cycles; canonical occupancy matches across worker counts;
forward/backward/forward restores bytes exactly within each history. Report live
allocation, retained pool, scratch, history disk use, peak RSS, seek/load and render
latency separately. Use at least five measured repetitions on the reference machine;
no unexplained >10% regression on the frozen suite. Publish resource failures too.
A parallel or sparse implementation ships only if its measured benefit justifies
its memory and maintenance cost.

**Dependency:** numerical and collision semantics from milestones 1–2. Metal cutting
remains optional after independent CPU oracles and these gates are stable.

### 4. Deliver an embeddable milling SDK beta

**User outcome:** an external developer can embed the engine without copying CLI
internals or reverse-engineering files.

Introduce a small C-compatible boundary around actual supported operations, with
explicit ownership/allocators, version negotiation, stable error categories,
progress/cancellation and query/report lifetimes. Keep simulation independent of
Swift/Metal. Document coordinate frames, units, unsupported operations, failure
atomicity, collision semantics and persistence compatibility. Add optional CAD
conversion as a separate adapter if corpus demand warrants it; do not build a STEP
kernel in the engine.

**Exit gate:** two small independent hosts use the public interface—one headless
and one interactive. Examples cover import, motion, inspection and resume. Fuzz
JSON/STL/state/history boundaries and run allocation-failure tests on exported
operations. A published compatibility policy and migration tests cover supported
saved formats. Pilot users reproduce the corpus and report issues through a
minimal reproducible-job package. No placeholder API counts toward completion.

**Dependency:** milestones 1–3 establish the actual supported contract. Packaging
and API design can proceed alongside measurement, but beta qualification cannot.

### 5. Broaden machining only through independent capability gates

**User outcome:** each additional machining mode has its own dependable semantics,
not merely an attractive animation.

First expand fixed tilted orientation and tool/assembly geometry on the production
corpus. Then treat simultaneous translation/orientation change as a separate
research and validation milestone: explicit orientation interpolation, shortest-path
convention, rotational displacement bound using the entire cutting assembly's
extent, continuous coverage, and reported approximation error.

Turning must separately specify spindle axis/phase, tool/workpiece transforms and
the difference between a rotational envelope and angle-resolved cutting. Longitudinal,
facing and asymmetric-stock cases need independent analytic oracles. Claim mill-turn
only after both modes operate on the same material state with tested transforms.

**Exit gate:** independent swept-volume/turning references, tangency and split/reversed
motion tests, explicit restrictions and complete resume/history coverage for each
mode. If the approximation cannot meet the declared bound, reject the operation.
No production 5-axis or mill-turn claim is based solely on feature count.

**Dependency:** the milling beta has demonstrated value and robustness. New modes
must not displace unresolved defects in the supported milling product.

## Release and comparison policy

Use three labels consistently: **experimental**, **validated within a stated
envelope**, and **qualified for a named integration/corpus**. Qualification never
means every possible machining case has been proved correct. Maintain the capability
matrix, raw benchmark records and known failures with every release.

Formal work follows actual risks: add theorems only when they clarify a numerical,
storage or concurrency contract and provide a meaningful implementation bridge.
The current Lean checks do not certify STL parsing, every sweep predicate, the
viewer or a complete executable. Do not increase theorem count as a proxy for
product readiness.

A performance comparison with ModuleWorks or another industrial engine requires
lawful access to both implementations, the same input geometry/path, equivalent
accuracy settings, agreed measurement phases and verified output differences.
Until then, report Menkh's measurements alone. A comparison with Jens likewise
requires aligned definitions of voxel tests, surface voxels and continuous motion.

Do not assign a parity percentage or delivery date from this list. Reassess effort
and scheduling after the first external corpus has exposed its failure modes.
The next product priority is **milestone 1 plus the contact/inspection contract from
milestone 2**; the next measured performance target remains ball-sweep evaluation.
