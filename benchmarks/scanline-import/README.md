# Shared-scanline STL import evidence

See [results, safeguards and reproduction](../../docs/SCANLINE-IMPORT.md).

- `raw.json.gz`: six whole-job reports, one warm-up and two measured repetitions
  per executable, with byte-exact imported-buffer hashes and canonical occupancy.
- `identifiers.json`, `environment.json`: measured working-tree sources, binary
  hashes, hardware and generated fixture identities. HEAD records the actual base
  during measurement; it is not a claim that uncommitted changes were already there.
- `resume-*`, `replay.json`: full 25 µm resume/compaction and native replay checks.
- `resolution-validation.json.gz`: final-state equality at 250, 100 and 50 µm;
  these are validation runs, not repeated performance measurements.
- `transformed-oracles.json`, `existing-oracles.json`: accepted fixture comparisons
  and explicitly rejected cases. No rejected mesh is counted as validated occupancy.
- `baseline-restrictions.json`, `local-coordinate-diagnostic.json`: the retained
  baseline also rejects those meshes, including with the translation removed.
- `varied.json.gz`, logs: existing varied suite and Debug/ReleaseFast/formal checks.
- `exploratory.json.gz`: first exploratory run, excluded from paired timing claims.

After running the paired benchmark with `--out out/scanline/paired`, execute
`python3 benchmarks/scanline-import/validate-resume.py` from the repository root
to reproduce the resume and complete delta-byte comparisons. The ordinary
`scripts/finishing-workflow.py` remains the one-command full workflow.

Large generated STLs, checkpoints and history files are reproduced rather than
committed. Local validation does not assert remote CI success.
