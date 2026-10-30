import Mathlib.Data.Finset.Card
import Mathlib.Tactic

/-! Discrete material semantics. Coordinates and masks are independent of geometry.
The integer mapping is the one used by Grid.occupied; arithmetic here is unbounded.
-/
namespace Menkh

abbrev Cell := Fin 8 × Fin 8 × Fin 8
abbrev Bits := Fin 8 → BitVec 64

def bitIndex (x y : Fin 8) : Fin 64 := ⟨y.val * 8 + x.val, by omega⟩

theorem address_roundtrip (i : Nat) : i / 8 * 8 + i % 8 = i := by omega

theorem bitIndex_injective (x y x' y' : Fin 8)
    (h : bitIndex x y = bitIndex x' y') : x = x' ∧ y = y' := by
  have := congrArg Fin.val h
  simp only [bitIndex] at this
  constructor <;> apply Fin.ext <;> omega

def valid (extent : Fin 3 → Nat) (c : Cell) : Bool :=
  decide (c.1.val < extent 0 ∧ c.2.1.val < extent 1 ∧ c.2.2.val < extent 2)

theorem boundary_mask_exact (e : Fin 3 → Nat) (c : Cell) :
    valid e c = true ↔ c.1.val < e 0 ∧ c.2.1.val < e 1 ∧ c.2.2.val < e 2 := by
  simp [valid]

inductive Descriptor where
  | empty
  | full
  | mixed (bits : Cell → Bool)

def decode (e : Fin 3 → Nat) : Descriptor → Cell → Bool
  | .empty, _ => false
  | .full, c => valid e c
  | .mixed b, c => b c

theorem materialize_full (e : Fin 3 → Nat) :
    decode e (.mixed (valid e)) = decode e .full := rfl

def readBits (b : Bits) (c : Cell) : Bool :=
  (b c.2.2).getLsbD (bitIndex c.1 c.2.1).val

def subtractBits (b mask : Bits) : Bits := fun z => b z &&& ~~~(mask z)

theorem word_subtraction_exact (b mask : Bits) (c : Cell) :
    readBits (subtractBits b mask) c = (readBits b c && !readBits mask c) := by
  simp [readBits, subtractBits, (bitIndex c.1 c.2.1).isLt]

-- Specification of popCount as the sum of its 64 bits, not an assumption about
-- a hardware intrinsic. The executable bridge tests Zig's actual @popCount.
def countBits (b : Bits) : Nat :=
  ∑ z : Fin 8, ∑ y : Fin 8, ∑ x : Fin 8,
    if readBits b (x, y, z) then 1 else 0

theorem population_exact (b : Bits) : countBits b =
    ∑ z : Fin 8, ∑ y : Fin 8,
      ((Finset.univ : Finset (Fin 8)).filter (fun x => readBits b (x,y,z))).card := by
  simp only [countBits, Finset.card_eq_sum_ones, Finset.sum_filter]

abbrev Material (I : Type) := I → Bool

def subtract {I : Type} (s cut : Material I) : Material I := fun i => s i && !cut i

theorem subtraction_spec {I : Type} (s cut : Material I) (i : I) :
    subtract s cut i = true ↔ s i = true ∧ cut i = false := by simp [subtract]

theorem subtraction_monotone {I : Type} (s cut : Material I) (i : I)
    (h : subtract s cut i = true) : s i = true := (subtraction_spec s cut i).mp h |>.1

theorem subtraction_idempotent {I : Type} (s cut : Material I) :
    subtract (subtract s cut) cut = subtract s cut := by
  funext i; simp [subtract]

inductive Classification where | outside | inside | mixed

def accelerated {I : Type} (s cut candidate : Material I)
    (classify : I → Classification) : Material I := fun i =>
  if !candidate i then s i else
    match classify i with
    | .outside => s i
    | .inside => false
    | .mixed => s i && !cut i

/-- Conditional refinement: these are precisely the geometric obligations that
an actual candidate-range and classifier implementation must discharge. -/
theorem accelerated_eq_scalar {I : Type} (s cut candidate : Material I)
    (classify : I → Classification)
    (range_sound : ∀ i, cut i = true → candidate i = true)
    (outside_sound : ∀ i, classify i = .outside → cut i = false)
    (inside_sound : ∀ i, classify i = .inside → cut i = true) :
    accelerated s cut candidate classify = subtract s cut := by
  funext i
  cases hc : candidate i with
  | false =>
    have hcut : cut i = false := by
      cases ht : cut i with
      | false => rfl
      | true => have := range_sound i ht; simp_all
    simp [accelerated, subtract, hc, hcut]
  | true =>
    cases ht : classify i with
    | outside => simp [accelerated, subtract, hc, ht, outside_sound i ht]
    | inside => simp [accelerated, subtract, hc, ht, inside_sound i ht]
    | mixed => simp [accelerated, subtract, hc, ht]

end Menkh
