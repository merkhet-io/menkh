#!/usr/bin/env python3
"""Validate an actual macOS --live run against a completed reference result.

This checks persistence and exact material, not perceptual smoothness or FPS.
Native run: menkh-viewer job.json --live --run-only --job-output NEW_DIRECTORY
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--result', type=Path, required=True)
p.add_argument('--reference', type=Path, required=True)
a = p.parse_args()
rows = [json.loads(line) for line in (a.result / 'live-viewer.jsonl').read_text().splitlines()]
assert len(rows) >= 3, 'Need several actual live handovers'
assert not rows[0]['persistent_view']
assert all(row['persistent_view'] for row in rows[1:]), 'Drawable view was replaced'
assert all(x['sequence'] < y['sequence'] for x, y in zip(rows, rows[1:]))
assert all(x['displayed_operation'] <= y['displayed_operation'] for x, y in zip(rows, rows[1:])), 'Follow replay went backwards'
assert all(row['first_operation'] <= row['displayed_operation'] <= row['completed_operations'] for row in rows)
assert sum(row['previous_window_draws'] for row in rows) > len(rows), 'No rendering between publications'
state = (a.result / 'final.menkh').read_bytes()
assert state == (a.reference / 'final.menkh').read_bytes(), 'Material changed'
gaps = [row['previous_window_max_draw_gap_ms'] for row in rows[1:]]
print(json.dumps(dict(windows=len(rows), persistent_view=True, monotone_follow=True,
    final_state_sha256=hashlib.sha256(state).hexdigest(),
    rendered_draws_before_last_window=sum(row['previous_window_draws'] for row in rows),
    load_prepare_ms_median=statistics.median(row['load_upload_ms'] for row in rows),
    per_window_max_draw_gap_ms_median=statistics.median(gaps),
    max_draw_gap_ms=max(gaps),
    note='Draw callback gaps include preparation handoff, replay and optional evidence captures. Not presented-frame timing or FPS.'), indent=2))
