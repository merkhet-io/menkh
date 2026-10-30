import Cutting
import Lean

-- Verify that the checks produced actual declarations, then audit their proof
-- dependencies. Merely seeing green SMT status is not sufficient.
open Lean Elab Command in
run_cmd do
  let env ← getEnv
  let mut checked := 0
  for actionName in #["initializer", "cut", "undo", "redo", "reject"] do
    for inv in #["remaining_within_stock", "snapshot_within_stock", "removed_was_present",
        "applied_partition", "applied_disjoint", "undo_restores", "doesNotThrow"] do
      let name := Name.mkSimple "Cutting" |>.str (actionName ++ "_" ++ inv)
      unless env.contains name do throwError "Missing generated proof {name}"
      let axioms ← collectAxioms name
      for ax in axioms do
        unless ax == `propext || ax == `Classical.choice || ax == `Quot.sound do
          throwError "{name} depends on disallowed axiom {ax}"
      checked := checked + 1
  for actionName in #["initializer", "bind", "release", "capture", "checkpoint"] do
    for inv in #["unique_owner", "snapshot_stable", "doesNotThrow"] do
      let name := Name.mkSimple "Pool" |>.str (actionName ++ "_" ++ inv)
      unless env.contains name do throwError "Missing generated proof {name}"
      for ax in ← collectAxioms name do
        unless ax == `propext || ax == `Classical.choice || ax == `Quot.sound do
          throwError "{name} depends on disallowed axiom {ax}"
      checked := checked + 1
  -- Include initializer and any helper theorems, not only the expected actions.
  let mut total := 0
  for (name, info) in env.constants.toList do
    if ((`Cutting).isPrefixOf name || (`Pool).isPrefixOf name) && info matches .thmInfo _ then
      total := total + 1
      for ax in ← collectAxioms name do
        unless ax == `propext || ax == `Classical.choice || ax == `Quot.sound do
          throwError "{name} depends on disallowed axiom {ax}"
  logInfo m!"Veil audit: {checked} required action proofs; {total} total theorems checked."
