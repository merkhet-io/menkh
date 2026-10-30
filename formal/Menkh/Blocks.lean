import Mathlib.Analysis.Convex.Combination
import Mathlib.Analysis.Convex.Segment
import Mathlib.Tactic

namespace Menkh.Blocks

/-- Real-arithmetic justification of the padded voxel candidate bounds.
Integer overflow and floating rounding are separate implementation obligations. -/
theorem candidate_range (low high h : ℝ) (i : ℕ) (hh : 0 < h)
    (hit : low ≤ (i+1/2 : ℝ)*h ∧ (i+1/2 : ℝ)*h ≤ high) :
    (⌊low/h⌋ : ℝ)-1 ≤ i ∧ (i : ℝ) < (⌈high/h⌉ : ℝ)+1 := by
  have hl := Int.floor_le (low/h)
  have hu := Int.le_ceil (high/h)
  have hli : low/h ≤ (i+1/2 : ℝ) := (div_le_iff₀ hh).mpr (by nlinarith [hit.1])
  have hui : (i+1/2 : ℝ) ≤ high/h := (le_div_iff₀ hh).mpr (by nlinarith [hit.2])
  constructor <;> linarith

/-- Corners suffice only for convex cuts. This theorem explicitly requires that
property; it does not justify using corner tests for arbitrary nonconvex tools. -/
theorem corners_inside {n : ℕ} (lo hi p : Fin n → ℝ) (S : Set (Fin n → ℝ))
    (convex : Convex ℝ S) (ordered : ∀ i, lo i ≤ hi i)
    (corners : Set.pi Set.univ (fun i => {lo i, hi i}) ⊆ S)
    (point : ∀ i, lo i ≤ p i ∧ p i ≤ hi i) : p ∈ S := by
  apply convexHull_min corners convex
  rw [convexHull_pi]
  intro i _
  change p i ∈ convexHull ℝ {lo i, hi i}
  rw [convexHull_pair, segment_eq_Icc (ordered i)]
  exact point i

/-- Lipschitz distance exclusion: a block-radius test cannot skip an inside
point when its distance predicate satisfies the stated metric bound. -/
theorem distance_outside (dcenter dpoint radius tolerance : ℝ)
    (bound : dcenter - dpoint ≤ radius)
    (outside : radius + tolerance < dcenter) : tolerance < dpoint := by
  linarith

/-- Complementary whole-block inclusion with the opposite one-sided bound. -/
theorem distance_inside (dcenter dpoint radius tolerance : ℝ)
    (bound : dpoint - dcenter ≤ radius)
    (inside : dcenter + radius ≤ tolerance) : dpoint ≤ tolerance := by
  linarith

end Menkh.Blocks
