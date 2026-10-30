# Finishing protocol v1 evidence

See [the results report](../../docs/FINISHING-RESULTS.md) and
[frozen protocol](../../docs/FINISHING-PROTOCOL.md). JSON gzip files retain complete
per-operation records; decompress with `gzip -dc FILE.json.gz`.

- `full-raw`: warm-up and two 25 µm measurements.
- `baseline-raw`, `smoke-raw`: clean before/after runs, including baseline timeout.
- `resume`: checkpoint and compacted-resume reports with exact occupancy digest.
- `resolution-matrix`, `accuracy`: imported resolution runs and independent analytic sections.
- `geometry`, `tighter-geometry`, `tolerance-sensitivity`: error-source separation and diagnostic.
- `varied-baseline`, `varied-final`: existing suite, including unfavorable timings.
- `exploratory-*`: earlier runs with concurrent work; not used for clean speedup claims.
- `manifest`, `identifiers`: actual source/binary/fixture hashes and hardware.
- `render`, `replay`: native Metal measurements and byte-exact history checks.
- `cpu-sample`: sampled warm-up cutting stack, not a measured repetition.
- Test logs, independent import-oracle and integration records are retained alongside these.

Production sources match the implementation commit in the manifest. The original
measurement HEAD remains recorded honestly; additional tests and documentation were
committed later. Raw records contain local output paths; regenerate those artifacts
with the workflow script. State/history binaries and generated STLs are not checked
in. Their generation, checksums and comparisons are reproducible. Cached writes are
not durable-storage benchmarks. No remote CI execution is implied by local logs.
