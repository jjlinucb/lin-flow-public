/-
Spoken commands: `spoken_command` in `next/service/src/command.rs`.

Promise: Lin Flow runs a take as a command only when it starts with the wake word, or with one
greeting (hey, ok, okay, hi) and then the wake word. What it hands to Zap is only the words said
after the wake word, and there has to be at least one. Every other take is pasted as dictation.

The model works on the take's words, split on whitespace, which is how the Rust walks it.
`next/service/tests/proofs.rs` runs the real function on the takes in `vectors.json` and fails on
any difference. Not modelled: the command key and the `heard_as` mishearings (`Hook::command`),
and letters outside ASCII, which the Rust lowercases by Unicode rules and the model does not.
-/
namespace LinFlow.Command

/-- A word's letters and digits, lowercased: "Zap," and "zap" are the same word. -/
def letters (s : String) : String :=
  String.ofList ((s.toList.filter Char.isAlphanum).map Char.toLower)

/-- The wake word, or the engine's spelling of it with the last letter doubled ("Zapp"). -/
def wake (want got : String) : Bool :=
  got == want ||
    (got.length == want.length + 1 && want.toList.isPrefixOf got.toList &&
      got.toList.getLast? == want.toList.getLast?)

def greeting (w : String) : Bool := w == "hey" || w == "ok" || w == "okay" || w == "hi"

def punctOnly (w : String) : Bool := w.toList.all (fun c => ",.:;!?-".toList.contains c)
def commaOnly (w : String) : Bool := w.toList.all (fun c => c == ',' || c == '.')

/-- Something is left to run once punctuation is set aside. -/
def hasWord (ws : List String) : Bool := ws.any (fun w => !punctOnly w)

def afterWake (want : String) : List String → Option (List String)
  | [] => none
  | w :: rest => if wake want (letters w) && hasWord rest then some rest else none

/-- The words handed to Zap, or `none` when the take is dictation. -/
def spoken (word : String) (ws : List String) : Option (List String) :=
  let want := letters word
  if want.isEmpty then none
  else match ws with
    | [] => none
    | w :: rest =>
      if wake want (letters w) then (if hasWord rest then some rest else none)
      else if greeting (letters w) then afterWake want (rest.dropWhile commaOnly)
      else none

theorem afterWake_some (want : String) (ws c : List String) (h : afterWake want ws = some c) :
    ∃ w, ws = w :: c ∧ wake want (letters w) = true ∧ hasWord c = true := by
  cases ws with
  | nil => simp [afterWake] at h
  | cons w rest =>
    simp only [afterWake] at h
    split at h
    · rename_i hc
      simp only [Bool.and_eq_true] at hc
      cases h; exact ⟨w, rfl, hc.1, hc.2⟩
    · cases h

/-- **The promise.** -/
theorem only_after_the_wake_word (word : String) (ws c : List String)
    (h : spoken word ws = some c) :
    ∃ pre w, ws = pre ++ w :: c ∧ wake (letters word) (letters w) = true ∧ hasWord c = true ∧
      (pre = [] ∨ ∃ g ps, pre = g :: ps ∧ greeting (letters g) = true ∧
        ∀ p ∈ ps, commaOnly p = true) := by
  unfold spoken at h
  simp only at h
  split at h
  · cases h
  · split at h
    · cases h
    · rename_i w rest
      split at h
      · rename_i hw
        split at h
        · rename_i hr; cases h
          exact ⟨[], w, rfl, hw, hr, Or.inl rfl⟩
        · cases h
      · split at h
        · rename_i hg
          obtain ⟨w', hd, hw', hc⟩ := afterWake_some _ _ _ h
          refine ⟨w :: rest.takeWhile commaOnly, w', ?_, hw', hc, Or.inr ⟨w, _, rfl, hg, ?_⟩⟩
          · have := List.takeWhile_append_dropWhile (p := commaOnly) (l := rest)
            rw [hd] at this
            rw [List.cons_append, this]
          · intro p hp
            exact List.all_eq_true.mp (List.all_takeWhile (p := commaOnly) (l := rest)) p hp
        · cases h

end LinFlow.Command
