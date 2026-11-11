/-
Prints `vectors.json`: takes, and what the proved model of spoken commands answers for each.
`next/service/tests/proofs.rs` runs the real `spoken_command` on the same takes and fails on any
difference. Rebuilt by `next/core/tests/proofs.rs` when Lean is installed; never edit by hand.
-/
import LinFlow
open LinFlow.Command

def lcg (x : Nat) : Nat := (x * 1103515245 + 12345) % 2147483648

/-- Words a take might start with, wake words and near misses among them. -/
def pool : Array String :=
  #["Zap", "zap", "Zap,", "Zapp.", "ZAPP", "Zappp", "Za", "zap:", "Zapdos", "Zapdoss", "Zapdos,",
    "Hey", "hey,", "OK", "Okay,", "Hi", "Hello", ",", ".", "-", "?!", ",.", "...", "open", "my",
    "notes", "work", "laptop.", "Do", "not", "disturb", "-on", "zapping", "the", "2"]

def take (seed : Nat) : List String × Nat := Id.run do
  let mut x := lcg seed
  let n := (x / 65536) % 6
  let mut out := #[]
  for _ in [0:n] do
    x := lcg x
    out := out.push pool[(x / 65536) % pool.size]!
  return (out.toList, x)

def quote (s : String) : String := "\"" ++ s ++ "\""
def jsonList (xs : List String) : String := "[" ++ ",".intercalate xs ++ "]"

def main : IO Unit := do
  let mut seed := 11
  let mut cases := #[]
  for word in ["Zap", "Zapdos"] do
    for i in [0:1500] do
      let (ws, s) := take seed
      seed := s
      -- Two spaces now and then: the Rust splits on any run of whitespace.
      let text := (if i % 7 == 0 then "  " else " ").intercalate ws
      let want := match spoken word ws with
        | none => "null"
        | some c => jsonList ((c.map letters).filter (· ≠ "") |>.map quote)
      cases := cases.push s!"\{\"word\":{quote word},\"take\":{quote text},\"command\":{want}}"
  IO.println s!"\{\"command\": {jsonList cases.toList}}"
