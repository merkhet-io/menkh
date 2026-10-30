import Menkh.Occupancy

/-! Abstract occupancy deltas and history-safe pool transitions in ordinary Lean.
These contracts do not verify the Zig binary history format or allocator. -/
namespace Menkh.History

def removed {I : Type} (s cut : Material I) : Material I := fun i => s i && cut i

def restore {I : Type} (after delta : Material I) : Material I := fun i => after i || delta i

theorem removed_was_present {I : Type} (s cut : Material I) (i : I)
    (h : removed s cut i = true) : s i = true := by
  have both : s i = true ∧ cut i = true := by simpa [removed] using h
  exact both.1

theorem cut_partition {I : Type} (s cut : Material I) (i : I) :
    s i = (subtract s cut i || removed s cut i) := by
  cases hs : s i <;> cases hc : cut i <;> simp [subtract, removed, hs, hc]

theorem cut_disjoint {I : Type} (s cut : Material I) (i : I) :
    (subtract s cut i && removed s cut i) = false := by
  cases hs : s i <;> cases hc : cut i <;> simp [subtract, removed, hs, hc]

theorem undo_restores {I : Type} (s cut : Material I) :
    restore (subtract s cut) (removed s cut) = s := by
  funext i
  exact (cut_partition s cut i).symm

theorem redo_restores {I : Type} (s cut : Material I) :
    subtract (restore (subtract s cut) (removed s cut)) cut = subtract s cut := by
  rw [undo_restores]

theorem cut_preserves_stock {I : Type} (s cut stock : Material I)
    (within : ∀ i, s i = true → stock i = true) :
    ∀ i, subtract s cut i = true → stock i = true := by
  intro i h
  exact within i (subtraction_monotone s cut i h)

/-- Ownership and retained payloads are abstract relations. -/
structure Pool (B S P : Type) where
  owns : B → S → Prop
  contents : S → P
  remembered : S → P → Prop

def WellFormed {B S P : Type} (p : Pool B S P) : Prop :=
  (∀ b c s, p.owns b s → p.owns c s → b = c) ∧
  (∀ s v, p.remembered s v → p.contents s = v)

def initial {B S P : Type} (contents : S → P) : Pool B S P :=
  ⟨fun _ _ => False, contents, fun _ _ => False⟩

theorem initial_wellFormed {B S P : Type} (contents : S → P) :
    WellFormed (initial (B := B) contents) := by
  simp [WellFormed, initial]

def bind {B S P : Type} [DecidableEq B] [DecidableEq S]
    (p : Pool B S P) (b : B) (s : S) (v : P) : Pool B S P :=
  ⟨fun c t => if c = b then t = s else p.owns c t,
   fun t => if t = s then v else p.contents t, p.remembered⟩

theorem bind_preserves {B S P : Type} [DecidableEq B] [DecidableEq S]
    (p : Pool B S P) (b : B) (s : S) (v : P) (wf : WellFormed p)
    (not_live : ∀ c, ¬ p.owns c s)
    (not_retained : ∀ w, ¬ p.remembered s w) :
    WellFormed (bind p b s v) := by
  constructor
  · intro c d t hc hd
    change (if c = b then t = s else p.owns c t) at hc
    change (if d = b then t = s else p.owns d t) at hd
    by_cases hcb : c = b <;> by_cases hdb : d = b
    · exact hcb.trans hdb.symm
    · simp only [hcb, hdb, if_true, if_false] at hc hd
      subst t
      exact False.elim (not_live d hd)
    · simp only [hcb, hdb, if_true, if_false] at hc hd
      subst t
      exact False.elim (not_live c hc)
    · simp only [hcb, hdb, if_false] at hc hd
      exact wf.1 c d t hc hd
  · intro t w h
    change (if t = s then v else p.contents t) = w
    by_cases hts : t = s
    · subst t
      exact False.elim (not_retained w h)
    · simp only [hts, if_false]
      exact wf.2 t w h

def release {B S P : Type} (p : Pool B S P) (b : B) : Pool B S P :=
  { p with owns := fun c t => c ≠ b ∧ p.owns c t }

theorem release_preserves {B S P : Type} (p : Pool B S P) (b : B)
    (wf : WellFormed p) : WellFormed (release p b) := by
  exact ⟨fun c d t hc hd => wf.1 c d t hc.2 hd.2, wf.2⟩

def capture {B S P : Type} (p : Pool B S P) (s : S) : Pool B S P :=
  { p with remembered := fun t v => p.remembered t v ∨ (t = s ∧ v = p.contents s) }

theorem capture_preserves {B S P : Type} (p : Pool B S P) (s : S)
    (wf : WellFormed p) : WellFormed (capture p s) := by
  refine ⟨wf.1, ?_⟩
  intro t v h
  rcases h with h | ⟨rfl,rfl⟩
  · exact wf.2 t v h
  · rfl

def checkpoint {B S P : Type} (p : Pool B S P) : Pool B S P :=
  { p with remembered := fun _ _ => False }

theorem checkpoint_preserves {B S P : Type} (p : Pool B S P)
    (wf : WellFormed p) : WellFormed (checkpoint p) := by
  exact ⟨wf.1, fun _ _ h => False.elim h⟩

end Menkh.History
