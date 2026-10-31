# Changelog

User-visible changes to Menkh, newest first. No version tags or GitHub releases
have been published yet: the dated sections record **merged development history**,
not numbered releases. Dates follow the repository's merge history.

For current support and restrictions, see the [capability matrix](docs/CAPABILITIES.md).
Benchmark results remain tied to their documented hardware, workload and build.
Voxel spacing is not a guaranteed surface-error bound; Lean proofs cover selected
mathematical models, not the complete executable.

## In review

- **Windows live inspection:** `--live` follows leased completed-operation
  windows in DLL and subprocess mode, with pause/resume, held-history seeking,
  cooperative cancellation and handoff to full-history playback. Native Win32
  and D3D12 tests cover both runners. Optional live comparison/provenance
  overlays remain separate follow-ups. ([#37](https://github.com/merkhet-io/menkh/pull/37))

## 2026-10-31

### Added

- **Live inspection on macOS:** completed-operation material windows, independent
  follow/hold controls, pause/resume, cooperative cancellation and retained-range
  scrubbing. Three leased slots bound publication; a 25 µm ball-end demo and
  byte-exact replay checks document the workflow. Windows pointer replacement
  handles file-sharing conflicts explicitly. ([#33])
- **C embedding API:** shared and static libraries, opaque material handles,
  geometric operations and queries, copied-history undo/redo, and saved-state
  loading/writing. Added complete JSON-job execution with progress and
  operation-boundary cancellation. The Windows viewer can run jobs through the
  adjacent `menkh.dll`. See the [API contract](docs/C-API.md). ([#27], [#28])
- **Bounded wheel grinding:** cylindrical wheels and explicit XYZAC motion,
  followed by piecewise-linear rotational profiles with caps and nonconvex waists.
  Continuous-coverage bounds and independent geometric checks are documented;
  this is not unrestricted five-axis machining. See [grinding](docs/GRINDING.md).
  ([#25], [#31])
- **Sparse mutation experiment:** persistent material snapshots, cuts and retained
  history roots in virtual grids up to 65,536³. This remains separate from the
  regular job engine and viewer, without billion-surface-voxel qualification.
  See the [measurements and limitations](docs/SPARSE-MUTATION.md). ([#25])
- **Playback-wide exposure attribution:** opt-in `provenance_scope: "all_frames"`
  records operation/tool IDs for faces exposed throughout history. Both viewers
  support coloring while scrubbing; macOS also supports picking. The smaller
  final-surface index remains the default. ([#32])
- Adopted the **MIT License**, including the license notice in Windows packages.
  ([#30])

### Changed

- Added Windows operation/tool exposure colors and documented the different
  inspection capabilities of the macOS and Windows viewers. ([#25])
- Refreshed the Windows quick start and added the Menkh logo, Egyptian-name
  explanation and chisel sign to the README. ([#29])

### Fixed

- Corrected exposure attribution across playback frames, including checks that
  future operations cannot color earlier states. ([#32])
- Remove stale completion and inspection metadata before reusing a job output
  directory, so an interrupted run cannot leave a previous completion manifest
  alongside newly written history. ([#32])

## 2026-10-30

### Added

- **Initial Zig simulator:** compact 8³ block descriptors, pooled occupancy bits,
  continuous constant-Z cylindrical end-mill sweeps, scalar reference tests,
  statistics, PPM height images, voxel-boundary OBJ export and benchmarks. ([#1])
- **Drill demonstrations and native macOS viewing:** animated cutting of a
  cylindrical blank, an executed exact 4096 × 4096 × 4096 grid demo, reversible
  block history and direct Metal voxel rendering. These are idealized geometry
  demos, not production-qualified drill manufacturing. ([#1])
- **Reusable machining engine:** explicit origins and bounds; cuboid, cylinder,
  sphere and primitive-union stock; flat, ball, bull-nose, tapered and idealized
  drill cutters; fixed-orientation straight sweeps and bounded arc/helical motion.
  Added a reviewed pocket-milling demo. ([#3])
- **Jobs, geometry input and inspection:** versioned JSON jobs, closed binary-STL
  stock/targets, resumable checkpoints, reversible history, target excess/missing
  material comparison, point/ray queries, cross-sections and geometric
  cutter/shank/holder/fixture checks. ([#3])
- **Restricted turning envelopes:** longitudinal and facing operations on the same
  voxel material state, with explicit spindle transforms. These represent
  full-revolution envelopes, not discrete spindle-angle or production mill-turn
  simulation. ([#3])
- **Formal verification and CI:** Lean models for occupancy, subtraction, selected
  geometry, history and pool contracts; axiom audits, Zig differential bridges
  and deliberately broken-implementation checks. Documented the scope of these
  proofs and their limits. ([#4], [#5])
- **Windows support:** standalone C++/D3D12 history viewer, MSVC build script and
  Visual Studio project, playback, camera controls and Z sections. Added Windows
  CLI tests, WARP rendering/replay checks and downloadable demo artifacts. ([#8])
- **Imported 25 µm ball-end finishing workflow:** frozen procedural stock/target
  fixtures, long toolpaths, save/resume and replay comparisons, independent
  accuracy checks, and phase-separated runtime/memory evidence. ([#9], [#10])
- **Defect-region inspection:** exact six-connected excess/missing regions,
  operation-linked collision findings, macOS filtering/focus/section/seek controls
  and regeneration of findings from saved states. ([#17])
- **Final-surface exposure colors:** optional operation/tool provenance export and
  native inspection of the operation that exposed a surviving voxel face. ([#19])
- **Viewer-owned calculations:** launch jobs from either viewer with progress,
  cancellation and automatic opening of the completed result. ([#22])
- Added `inspect-state` for boundary-voxel and exposed-face counts, separate from
  occupied material volume and mesh generation. ([#8])
- Job-level `--voxel` overrides and default drill histories that open in the
  Windows viewer. Saved-state resume
  requires matching grid spacing; it does not silently resample. ([#18])

### Changed

- Accelerated eligible flat-tool sweeps with CPU SIMD, reused XY coverage across
  Z blocks, conservative block culling and faster collision/height-image traversal.
  Added scalar comparisons and reproducible before/after measurements. Material
  updates still use one CPU worker; predicate microbenchmarks are separate from
  end-to-end cutting throughput. ([#6])
- Accelerated STL voxelization using conservative region filling and reusable
  scanline intervals with scalar fallback; improved general ball-end sweep
  evaluation while retaining declared motion semantics. ([#9], [#10])
- Hardened milling validation and clearance reporting, added a clamped finishing
  workload, and separated confirmed contact, unresolved clearance and checks that
  were not performed. ([#13])
- Recorded dense-grid resource failures and sparse snapshot tradeoffs rather than
  claiming support for 65,536³ production jobs or billions of surface voxels in
  bounded memory. ([#20])
- Translated the README and project documentation into English. ([#2])

---

Keep new entries under **In review** until merged, then move them to the relevant
merge date. When the project publishes versioned releases, group the applicable
entries under the actual version and release date; retain these historical dates.

[#1]: https://github.com/merkhet-io/menkh/pull/1
[#2]: https://github.com/merkhet-io/menkh/pull/2
[#3]: https://github.com/merkhet-io/menkh/pull/3
[#4]: https://github.com/merkhet-io/menkh/pull/4
[#5]: https://github.com/merkhet-io/menkh/pull/5
[#6]: https://github.com/merkhet-io/menkh/pull/6
[#8]: https://github.com/merkhet-io/menkh/pull/8
[#9]: https://github.com/merkhet-io/menkh/pull/9
[#10]: https://github.com/merkhet-io/menkh/pull/10
[#13]: https://github.com/merkhet-io/menkh/pull/13
[#17]: https://github.com/merkhet-io/menkh/pull/17
[#18]: https://github.com/merkhet-io/menkh/pull/18
[#19]: https://github.com/merkhet-io/menkh/pull/19
[#20]: https://github.com/merkhet-io/menkh/pull/20
[#22]: https://github.com/merkhet-io/menkh/pull/22
[#25]: https://github.com/merkhet-io/menkh/pull/25
[#27]: https://github.com/merkhet-io/menkh/pull/27
[#28]: https://github.com/merkhet-io/menkh/pull/28
[#29]: https://github.com/merkhet-io/menkh/pull/29
[#30]: https://github.com/merkhet-io/menkh/pull/30
[#31]: https://github.com/merkhet-io/menkh/pull/31
[#32]: https://github.com/merkhet-io/menkh/pull/32
[#33]: https://github.com/merkhet-io/menkh/pull/33
