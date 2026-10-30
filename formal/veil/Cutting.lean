import Veil

/-! Transactional cutting with one reversible checkpoint. Geometry is an
immutable, uninterpreted relation, deliberately separated from the real-arithmetic
proofs. No geometry correctness is assumed or claimed here. -/
set_option veil.smt.trust false
set_option veil.violationIsError true

veil module Cutting

type voxel
type operation
immutable relation stock : voxel → Bool
immutable relation cuts : operation → voxel → Bool
relation occupied : voxel → Bool
relation before : voxel → Bool
relation removed : voxel → Bool
individual saved : Bool
individual applied : Bool

#gen_state

after_init {
  occupied V := stock V
  before V := stock V
  removed V := false
  saved := false
  applied := false
}

-- A successful preflight permits an atomic commit. Rejection never enters this
-- transition. Only one checkpoint is retained in this model.
action cut (op : operation) {
  before V := occupied V
  removed V := occupied V ∧ cuts op V
  occupied V := occupied V ∧ ¬ cuts op V
  saved := true
  applied := true
}

action undo {
  require saved ∧ applied
  occupied V := before V
  applied := false
}

action redo {
  require saved ∧ ¬ applied
  occupied V := before V ∧ ¬ removed V
  applied := true
}

action reject {
  -- Validation or reservation failure: no material changes.
  return
}

invariant [remaining_within_stock] occupied V → stock V
invariant [snapshot_within_stock] before V → stock V
invariant [removed_was_present] removed V → before V
invariant [applied_partition] saved ∧ applied → (before V ↔ occupied V ∨ removed V)
invariant [applied_disjoint] saved ∧ applied → ¬ (occupied V ∧ removed V)
invariant [undo_restores] saved ∧ ¬ applied → (occupied V ↔ before V)

#gen_spec
#check_invariants
#gen_theorems

end Cutting

/-! Pool ownership contract for future slot reuse. This is an abstract model of
safe reuse, not a claim that the current Zig history allocator reuses slots. -/
veil module Pool

type block
type slot
type payload
relation owns : block → slot → Bool
function contents : slot → payload
relation remembered : slot → payload → Bool

#gen_state

after_init {
  owns B S := false
  remembered S P := false
}

-- Replacing a descriptor can release its old slot, but the replacement slot
-- must be neither live nor retained by history.
action bind (b : block) (s : slot) (p : payload) {
  require ∀ B, ¬ owns B s
  require ∀ P, ¬ remembered s P
  contents s := p
  owns b S := S = s
}

action release (b : block) {
  owns b S := false
}

action capture (b : block) (s : slot) {
  require owns b s
  remembered s (contents s) := true
}

-- Explicitly invalidates all retained snapshots, as a compaction checkpoint does.
action checkpoint {
  remembered S P := false
}

invariant [unique_owner] owns B S ∧ owns C S → B = C
invariant [snapshot_stable] remembered S P → contents S = P

#gen_spec
#check_invariants
#gen_theorems

end Pool
