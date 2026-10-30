# Milling robustness evidence

See [implementation, measurements and limits](../../docs/MILLING-ROBUSTNESS.md) and
[product roadmap](../../docs/PRODUCT-ROADMAP.md).

- `raw.json.gz`: alternating paired full-job reports, one warm-up and two measured
  runs per executable, with exact initial stock/target hashes and final occupancy.
- `identifiers.json`: actual measurement HEAD plus working-tree source hashes and
  both executable identities. `environment.json` records the final source identity,
  hardware, validation scripts, fixtures and viewer.
- `comment-correction.json`: a post-measurement regression-comment unit correction
  changed binary identity; machine-instruction section hashes remain identical.
- `ball-oracle.json`: independent continuous hemisphere/finite-flute interval checks,
  all coarse-grid centers and seeded fine-grid samples, plus scalar occupancy checks.
- `clamped-summary.json`, `safe-clamps-report.json.gz`, `unsafe-clamps-report.json.gz`:
  actual 25 µm clamp runs, selected independent assembly-contact counts and all
  operation IDs/regions/statuses. These are validation runs, not repeated benchmarks.
- `resume-*`, `replay.json`: full-resolution resumed/compacted state and native replay.
- Mesh-oracle records, Debug/ReleaseFast/formal logs and varied-suite reports retain
  validation evidence. The three previous parser rejection cases are now accepted.

Reproduce the paired run with:

```sh
python3 scripts/benchmark-import-cache.py --before /path/to/e6c7ce0/menkh --out out/milling-robustness/paired
python3 benchmarks/milling-robustness/validate-resume.py
```

Build the before executable separately using Zig 0.15.2 ReleaseFast. Fixture and
state/history binaries are generated rather than committed. Cached file writes are
not durable-storage measurements; local logs do not imply remote CI success.
