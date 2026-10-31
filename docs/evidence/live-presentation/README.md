# macOS live presentation check — 2026-10-31

Apple M5 Max, 128 GiB, native Swift/Metal viewer. Same 25 µm inspection job as
[the live-overlay measurements](../live-overlays/README.md): 2,501 operations,
1120 × 880 × 400 grid. These are individual diagnostic runs, not repeated
controlled performance benchmarks or displayed-frame/FPS measurements.

The earlier viewer recreated its entire view/controller every 500 ms and skipped
straight to the publication end. The fix retains the drawable layer and controls,
prepares one leased window on a background queue, reuses the Metal pipeline, and
paces exact recorded operations between publications. Live display defaults to
at most 1280 × 900 pixels; full Retina resolution is opt-in. Occupancy is unchanged.

## Final run

`final-raw.jsonl` and `final-check.json` record:

- 294 published windows adopted without view recreation; monotone operation IDs.
- 3,766 draw callbacks before the final window (not a presented-frame count).
- Median background preparation: 18.33 ms.
- Median of each window's maximum draw-callback gap: 17.58 ms; overall maximum:
  60.95 ms. No screenshot capture or replay verification ran during this run.
- Final checkpoint SHA-256:
  `380734c1fa84fac35f9e048174954a29b77cdd6542a321e3293a8744755df47d`,
  identical to the earlier reference; 124,282,033 occupied voxels.

There are still missed display deadlines; this does not establish locked 60 FPS.
Large cut steps, replay work, ray casting and publication/rebase gaps can remain
visible. No continuous tool animation or interpolated material is invented.

## Retained unfavorable runs

`uncapped-check.json` records an intermediate persistent-view/background-loader
run: 33.67 ms median per-window maximum gap and 218.50 ms overall maximum. Other
local validation/build activity overlapped that run; do not interpret the
comparison as a controlled speedup.

`initial-cap-raw.jsonl` and `initial-cap-check.json` preserve an intermediate
capped run with two approximately one-second outliers (worst 1,037.78 ms).
The final code avoids redundant drawable-size assignments during layout and
unnecessary control updates. Those outliers did not recur in the final run;
a single run does not prove that every stall is eliminated.

Full native forward/backward/forward replay passed with the persistent-view
implementation (`full-replay.json`). An independent seven-frame live exposure
and target oracle also passed. A saved in-progress image was inspected; it is
not evidence of temporal smoothness. The final run additionally checks drawable
identity at every handover and byte-exact final material with
`scripts/check-live-presentation.py`.

Reproduce:

```sh
./scripts/build-viewer.sh
python3 scripts/live-demo.py --inspection --out out/presentation-job.json
zig-out/bin/menkh-viewer out/presentation-job.json --live --color-operation \
  --run-only --job-output out/presentation-run
python3 scripts/check-live-presentation.py --result out/presentation-run \
  --reference out/reference-run
```

Use a completed result from the identical generated job as the reference.
Windows rendering and the simulation engine are unchanged by this fix.
