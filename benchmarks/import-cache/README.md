# Cached STL ray benchmark

See [results and reproduction](../../docs/IMPORT-CACHE-RESULTS.md).
`raw.json.gz` retains all six full-job reports (one warm-up and two measurements
per executable) and exact imported-buffer hashes. `identifiers.json` records the
actual HEAD plus measured working-tree sources and both executable hashes.
`summary.json` retains medians, ranges and memory. Test logs, smoke resume summary,
import oracles and varied-suite records document follow-up validation.

The pre-cache executable hash matches the original finishing evidence. No workload
or motion tolerance was changed. Cache memory is temporary but not free; whole-job
peak RSS happened to remain unchanged. Local results do not assert remote CI success.
