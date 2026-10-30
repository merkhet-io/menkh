import Menkh
import Lean

open Lean Elab Command in
run_cmd do
  let env ← getEnv
  let required := #[
    `Menkh.Blocks.candidate_range,
    `Menkh.Blocks.corners_inside,
    `Menkh.Blocks.distance_outside,
    `Menkh.Blocks.distance_inside,
    `Menkh.Geometry.clamp_mem,
    `Menkh.Geometry.radial_minimum,
    `Menkh.Geometry.nearest_mem,
    `Menkh.Geometry.radial_sweep_exact,
    `Menkh.Geometry.axial_clip_positive,
    `Menkh.Geometry.axial_clip_negative,
    `Menkh.Geometry.constant_z_product,
    `Menkh.Geometry.finite_cylinder_sweep,
    `Menkh.Geometry.flatContains_exact,
    `Menkh.History.removed_was_present,
    `Menkh.History.cut_partition,
    `Menkh.History.cut_disjoint,
    `Menkh.History.undo_restores,
    `Menkh.History.redo_restores,
    `Menkh.History.cut_preserves_stock,
    `Menkh.History.initial_wellFormed,
    `Menkh.History.bind_preserves,
    `Menkh.History.release_preserves,
    `Menkh.History.capture_preserves,
    `Menkh.History.checkpoint_preserves,
    `Menkh.address_roundtrip,
    `Menkh.bitIndex_injective,
    `Menkh.boundary_mask_exact,
    `Menkh.materialize_full,
    `Menkh.word_subtraction_exact,
    `Menkh.population_exact,
    `Menkh.subtraction_spec,
    `Menkh.subtraction_monotone,
    `Menkh.subtraction_idempotent,
    `Menkh.accelerated_eq_scalar
  ]
  for name in required do
    unless env.contains name do throwError "Missing required theorem {name}"
  let mut count := 0
  for (name, info) in env.constants.toList do
    if (`Menkh).isPrefixOf name && info matches .thmInfo _ then
      count := count + 1
      let axioms ← collectAxioms name
      for ax in axioms do
        unless ax == `propext || ax == `Classical.choice || ax == `Quot.sound do
          throwError "{name} depends on disallowed axiom {ax}"
  logInfo m!"Audited {required.size} named results and {count} total Menkh theorems: only propext, Classical.choice, Quot.sound allowed."
