import Menkh.Occupancy

/-! Executable finite corpus using the proved bit-subtraction function.
The bridge is differential testing, not proof of Zig refinement. -/
open Menkh

def pattern (seed z : Nat) : BitVec 64 := BitVec.ofNat 64
  (seed * 6364136223846793005 + z * 1442695040888963407 + 10330960521543213253)

def rationalCut (qx qy z vx vy vz : ℚ) : Bool := Id.run do
  let eps : ℚ := 1 / 10000000000
  let r : ℚ := 2 + eps
  let mut lo : ℚ := 0
  let mut hi : ℚ := 1
  if vz == 0 then
    if z < -eps || z > 3 + eps then return false
  else
    let t0 := (z - 3 - eps) / vz
    let t1 := (z + eps) / vz
    lo := max lo (min t0 t1)
    hi := min hi (max t0 t1)
    if lo > hi then return false
  let a := vx*vx + vy*vy
  let t := if a == 0 then lo else max lo (min hi ((qx*vx+qy*vy)/a))
  return (qx-t*vx)^2 + (qy-t*vy)^2 ≤ r*r

def coord (seed factor : Nat) : Int := ((seed*factor + seed/(factor+1)*17 + factor*factor) % 41 : Nat) - (20 : Int)

def main : IO Unit := do
  let out ← IO.getStdout
  for ex in [1:9] do
    for ey in [1:9] do
      for ez in [1:9] do
        let e : Fin 3 → Nat := ![ex,ey,ez]
        for z in [0:8] do
          let mut mask : Nat := 0
          for y in [0:8] do
            for x in [0:8] do
              if valid e (⟨x % 8, by omega⟩, ⟨y % 8, by omega⟩, ⟨z % 8, by omega⟩) then
                mask := mask + 2^(y*8+x)
          out.putStrLn s!"M {ex} {ey} {ez} {z} {mask}"
  for seed in [0:512] do
    let b : Bits := fun z => pattern seed z.val
    let mask : Bits := fun z => pattern (seed+97) (7-z.val)
    let remaining := subtractBits b mask
    for z in [0:8] do
      let zi : Fin 8 := ⟨z % 8, by omega⟩
      out.putStrLn s!"B {seed} {z} {(b zi).toNat} {(mask zi).toNat} {(remaining zi).toNat}"
  for i in [0:8192] do
    out.putStrLn s!"I {i} {i/8} {i%8}"

  for seed in [0:4096] do
    let nums := [coord seed 3, coord seed 7, coord seed 11,
      coord seed 13, coord seed 17, coord seed 19]
    let qs := nums.map (fun n => (n : ℚ)/4)
    let hit := rationalCut qs[0]! qs[1]! qs[2]! qs[3]! qs[4]! qs[5]!
    out.putStrLn s!"G {String.intercalate " " (nums.map toString)} {if hit then 1 else 0}"
