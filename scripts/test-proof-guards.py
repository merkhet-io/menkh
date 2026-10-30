#!/usr/bin/env python3
"""Negative controls: deliberately broken copies must fail verification.
Never modifies the checked-in proofs. Fails on unexpected infrastructure errors.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
stage = sys.argv[1] if len(sys.argv) == 2 else ""
if stage == "core":
    source = ROOT / "formal/Menkh/Occupancy.lean"
    bad = source.read_text().replace("b z &&& ~~~(mask z)", "b z ||| ~~~(mask z)")
    expected = "b mask : Bits"
    relative = "../out/negative-core.lean"
elif stage in ("veil", "veil-pool"):
    source = ROOT / "formal/veil/Cutting.lean"
    bad = source.read_text().replace("occupied V := occupied V ∧ ¬ cuts op V", "occupied V := occupied V ∨ cuts op V")
    expected = "remaining_within_stock"
    if stage == "veil-pool":
        bad = source.read_text().replace("  require ∀ P, ¬ remembered s P\n", "")
        expected = "snapshot_stable"
    relative = f"../../out/negative-{stage}.lean"
else:
    raise SystemExit("Usage: test-proof-guards.py core|veil")
assert bad != source.read_text()
output = ROOT / f"out/negative-{stage}.lean"
output.parent.mkdir(exist_ok=True)
output.write_text(bad)
lake_stage = "core" if stage == "core" else "veil"
setup = [] if stage == "core" else ["--setup", ".lake/build/ir/Cutting.setup.json"]
result = subprocess.run([str(ROOT / "scripts/formal-lake.sh"), lake_stage, "env", "lean", *setup, relative],
                        cwd=ROOT, text=True, capture_output=True, timeout=180)
log = result.stdout + result.stderr
(ROOT / f"out/negative-{stage}.log").write_text(log)
if result.returncode == 0 or expected not in log or "error:" not in log:
    print(log)
    raise SystemExit("Negative control did not fail for the intended proof obligation")
print(f"{stage}: deliberately broken implementation rejected by proof checks")
