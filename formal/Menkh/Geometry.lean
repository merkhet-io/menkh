import Mathlib.Tactic

/-! Real-arithmetic flat-cylinder sweep. Local orthonormal tool coordinates:
q = point - start, v = end - start, z is axial, x/y radial. No f64 claim.
Closed boundaries; radius and axial interval can include an explicit tolerance.
-/
namespace Menkh.Geometry

noncomputable def clamp (x lo hi : ℝ) := max lo (min hi x)

theorem clamp_mem (x lo hi : ℝ) (h : lo ≤ hi) :
    lo ≤ clamp x lo hi ∧ clamp x lo hi ≤ hi := by
  unfold clamp
  exact ⟨le_max_left _ _, max_le h (min_le_left _ _)⟩

noncomputable def radial (qx qy vx vy t : ℝ) := (qx - t*vx)^2 + (qy - t*vy)^2

/-- The actual radial minimizer, including stationary radial motion. -/
noncomputable def nearest (qx qy vx vy lo hi : ℝ) :=
  if vx^2 + vy^2 = 0 then lo
  else clamp ((qx*vx + qy*vy)/(vx^2 + vy^2)) lo hi

theorem radial_minimum (qx qy vx vy lo hi t : ℝ)
    (hlh : lo ≤ hi) (ht : lo ≤ t ∧ t ≤ hi) :
    radial qx qy vx vy (nearest qx qy vx vy lo hi) ≤ radial qx qy vx vy t := by
  unfold nearest
  split_ifs with hz
  · have hx : vx = 0 := by nlinarith [sq_nonneg vy]
    have hy : vy = 0 := by nlinarith [sq_nonneg vx]
    simp [radial, hx, hy]
  · have ha : 0 < vx^2 + vy^2 := by exact lt_of_le_of_ne (add_nonneg (sq_nonneg vx) (sq_nonneg vy)) (Ne.symm hz)
    set a := vx^2 + vy^2
    set b := qx*vx + qy*vy
    have identity (u : ℝ) : radial qx qy vx vy u =
        a*(u-b/a)^2 + (qx^2+qy^2-a*(b/a)^2) := by
      unfold radial
      dsimp [a, b]
      field_simp [show vx^2 + vy^2 ≠ 0 from hz]
      ring
    rw [identity, identity]
    unfold clamp
    by_cases hlow : b/a < lo
    · rw [min_eq_right (by linarith : b/a ≤ hi), max_eq_left (le_of_lt hlow)]
      have : (lo-b/a)^2 ≤ (t-b/a)^2 := by nlinarith [ht.1]
      nlinarith
    · by_cases hhigh : hi < b/a
      · rw [min_eq_left (le_of_lt hhigh), max_eq_right hlh]
        have : (hi-b/a)^2 ≤ (t-b/a)^2 := by nlinarith [ht.2]
        nlinarith
      · rw [min_eq_right (le_of_not_gt hhigh), max_eq_right (le_of_not_gt hlow)]
        nlinarith [sq_nonneg (t-b/a)]

theorem nearest_mem (qx qy vx vy lo hi : ℝ) (h : lo ≤ hi) :
    lo ≤ nearest qx qy vx vy lo hi ∧ nearest qx qy vx vy lo hi ≤ hi := by
  unfold nearest
  split_ifs
  · exact ⟨le_refl _, h⟩
  · exact clamp_mem _ _ _ h

/-- Exact elimination of the continuous time quantifier over an admitted interval. -/
theorem radial_sweep_exact (qx qy vx vy lo hi r : ℝ) (h : lo ≤ hi) :
    radial qx qy vx vy (nearest qx qy vx vy lo hi) ≤ r^2 ↔
    ∃ t : ℝ, lo ≤ t ∧ t ≤ hi ∧ radial qx qy vx vy t ≤ r^2 := by
  constructor
  · intro hr
    exact ⟨_, (nearest_mem _ _ _ _ _ _ h).1, (nearest_mem _ _ _ _ _ _ h).2, hr⟩
  · rintro ⟨t, ht0, ht1, hr⟩
    exact le_trans (radial_minimum _ _ _ _ _ _ _ h ⟨ht0, ht1⟩) hr

/-- Axial clipping for positive axial velocity, including closed tangencies. -/
theorem axial_clip_positive (z vz lower upper t : ℝ) (hv : 0 < vz) :
    (0 ≤ t ∧ t ≤ 1 ∧ lower ≤ z-t*vz ∧ z-t*vz ≤ upper) ↔
    max 0 ((z-upper)/vz) ≤ t ∧ t ≤ min 1 ((z-lower)/vz) := by
  rw [max_le_iff, le_min_iff, div_le_iff₀ hv, le_div_iff₀ hv]
  constructor
  · rintro ⟨h1,h2,h3,h4⟩
    exact ⟨⟨h1, by linarith⟩, h2, by linarith⟩
  · rintro ⟨⟨h1,h2⟩,h3,h4⟩
    exact ⟨h1,h3,by linarith,by linarith⟩

/-- Negative axial velocity swaps the two cap times. -/
theorem axial_clip_negative (z vz lower upper t : ℝ) (hv : vz < 0) :
    (0 ≤ t ∧ t ≤ 1 ∧ lower ≤ z-t*vz ∧ z-t*vz ≤ upper) ↔
    max 0 ((z-lower)/vz) ≤ t ∧ t ≤ min 1 ((z-upper)/vz) := by
  rw [max_le_iff, le_min_iff, div_le_iff_of_neg hv, le_div_iff_of_neg hv]
  constructor
  · rintro ⟨h1,h2,h3,h4⟩
    exact ⟨⟨h1, by linarith⟩, h2, by linarith⟩
  · rintro ⟨⟨h1,h2⟩,h3,h4⟩
    exact ⟨h1,h3,by linarith,by linarith⟩

/-- Constant-Z vertical cylinder sweep is a planar capsule × axial interval.
Capsule membership is defined independently as existence of a disk along the segment. -/
theorem constant_z_product (qx qy z vx vy lower upper r : ℝ) :
    (∃ t : ℝ, 0 ≤ t ∧ t ≤ 1 ∧ lower ≤ z ∧ z ≤ upper ∧
      radial qx qy vx vy t ≤ r^2) ↔
    lower ≤ z ∧ z ≤ upper ∧
      radial qx qy vx vy (nearest qx qy vx vy 0 1) ≤ r^2 := by
  constructor
  · rintro ⟨t,h0,h1,hz0,hz1,hr⟩
    exact ⟨hz0,hz1,(radial_sweep_exact _ _ _ _ _ _ _ (by norm_num)).mpr ⟨t,h0,h1,hr⟩⟩
  · rintro ⟨hz0,hz1,hr⟩
    obtain ⟨t,h0,h1,ht⟩ := (radial_sweep_exact _ _ _ _ _ _ _ (by norm_num)).mp hr
    exact ⟨t,h0,h1,hz0,hz1,ht⟩

/-- A finite cylinder sweep, once the axial clip interval has been computed.
The axial-clip equivalence is discharged above for either velocity sign; zero
velocity reduces to the constant-Z case. This theorem includes empty intervals. -/
theorem finite_cylinder_sweep (qx qy z vx vy vz lower upper lo hi r : ℝ)
    (clip : ∀ t : ℝ, (0 ≤ t ∧ t ≤ 1 ∧ lower ≤ z-t*vz ∧ z-t*vz ≤ upper) ↔
      (lo ≤ t ∧ t ≤ hi)) :
    (lo ≤ hi ∧ radial qx qy vx vy (nearest qx qy vx vy lo hi) ≤ r^2) ↔
    ∃ t : ℝ, 0 ≤ t ∧ t ≤ 1 ∧ lower ≤ z-t*vz ∧ z-t*vz ≤ upper ∧
      radial qx qy vx vy t ≤ r^2 := by
  constructor
  · rintro ⟨h,hr⟩
    obtain ⟨t,h0,h1,ht⟩ := (radial_sweep_exact _ _ _ _ _ _ _ h).mp hr
    obtain ⟨ha,hb,hc,hd⟩ := (clip t).mpr ⟨h0,h1⟩
    exact ⟨t,ha,hb,hc,hd,ht⟩
  · rintro ⟨t,h0,h1,hz0,hz1,hr⟩
    obtain ⟨hl,hu⟩ := (clip t).mp ⟨h0,h1,hz0,hz1⟩
    exact ⟨le_trans hl hu, (radial_sweep_exact _ _ _ _ _ _ _ (le_trans hl hu)).mpr ⟨t,hl,hu,hr⟩⟩

/-- Executable-structure real model: clipped axial interval plus its radial minimum. -/
noncomputable def flatContains (qx qy z vx vy vz lower upper r : ℝ) : Prop :=
  if vz = 0 then lower ≤ z ∧ z ≤ upper ∧
    radial qx qy vx vy (nearest qx qy vx vy 0 1) ≤ r^2
  else
    let lo := max 0 (if 0 < vz then (z-upper)/vz else (z-lower)/vz)
    let hi := min 1 (if 0 < vz then (z-lower)/vz else (z-upper)/vz)
    lo ≤ hi ∧ radial qx qy vx vy (nearest qx qy vx vy lo hi) ≤ r^2

/-- No clip-correctness assumption: all axial branches are discharged here. -/
theorem flatContains_exact (qx qy z vx vy vz lower upper r : ℝ) :
    flatContains qx qy z vx vy vz lower upper r ↔
    ∃ t : ℝ, 0 ≤ t ∧ t ≤ 1 ∧ lower ≤ z-t*vz ∧ z-t*vz ≤ upper ∧
      radial qx qy vx vy t ≤ r^2 := by
  by_cases hz : vz = 0
  · simpa [flatContains, hz] using (constant_z_product qx qy z vx vy lower upper r).symm
  · by_cases hp : 0 < vz
    · simp only [flatContains, hz, hp, ↓reduceIte]
      exact finite_cylinder_sweep _ _ _ _ _ _ _ _ _ _ _
        (fun t => axial_clip_positive z vz lower upper t hp)
    · have hn : vz < 0 := lt_of_le_of_ne (le_of_not_gt hp) hz
      simp only [flatContains, hz, hp, ↓reduceIte]
      exact finite_cylinder_sweep _ _ _ _ _ _ _ _ _ _ _
        (fun t => axial_clip_negative z vz lower upper t hn)

end Menkh.Geometry
