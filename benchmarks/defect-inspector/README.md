# Defect inspector evidence

`summary.json` records the single completed 25 µm clamped finishing run with
region export enabled, on Apple M5 Max / Zig 0.15.2 / ReleaseFast / one worker.
Source hashes identify the implementation on top of the recorded base commit.
This is not a repeated speed comparison. Internal total timing ends before report
serialization; cached file writes are not durable-storage measurements.

- Total internal time: 25.234423 s; cutting: 15.662173 s.
- Defect grouping, statistics and JSON export: 0.616612459 s.
- Peak process RSS: 133,283,840 bytes (133.28 decimal MB).
- 127 regions and 672 combined material/collision findings.

Compressed raw report, defect regions and viewer findings are retained alongside
Debug/ReleaseFast, formal, integration, native navigation and coarse smoke logs.
The native test validates every selection, deterministic saved-state regeneration,
and rejection of mismatched finding metadata. Existing Lean checks pass; the new
component algorithm and viewer are not part of that formal model.

Reproduce geometry with `scripts/clamped-finishing.py --voxel 0.025`, set
`export_defects: true` in its unsafe `job.json` and execute that job into a fresh
directory. Then run `scripts/test-defect-inspector.py --result DIR --job JOB --viewer`.
The fixture generator, paths, dimensions and motion tolerance are unchanged from
the prior clamped finishing experiment. See `docs/DEFECT-INSPECTOR.md` for commands
and saved screenshots. Full state/history files remain generated artifacts.
