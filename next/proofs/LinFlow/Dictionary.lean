/-
The dictionary file: `replacements_file` and `parse_replacements` in
`next/core/src/text/glossary.rs`.

Promise: saving the dictionary keeps, word for word, every line that isn't a correction (no
`=>` in it, or it starts with #). And reading the saved file back gives exactly the corrections
that were saved, in the same order.

The model works on lines and takes the line parser (`parse`) and the writer's test for a rule
line (`ruleLike`, a line with `=>` not starting with #) as given, with what it needs of them: a
written correction reads back as itself, Lin Flow's two header lines read as nothing, and a line
that is not rule-like reads as nothing. `next/core/tests/laws.rs` (`dictionary_save_*`) checks
those on the real code, and the whole promise on the real functions, over generated dictionaries.

Not promised: a rule-like line the parser cannot read, such as `=> Lin Flow` with nothing before
the arrow, is dropped on save. That is a question for John, not something changed here.
-/
namespace LinFlow.Dictionary

variable {Rule : Type} (parse : String → Option Rule) (render : Rule → String)
  (own ruleLike : String → Bool) (header keptHeader : String)

/-- The lines carried over. `own` marks blank lines and Lin Flow's two headers. -/
def kept (existing : List String) : List String :=
  existing.filter (fun l => !own l && !ruleLike l)

def save (rules : List Rule) (existing : List String) : List String :=
  header :: rules.map render ++
    (if kept own ruleLike existing = [] then [] else keptHeader :: kept own ruleLike existing)

/-- What reading a file gives. -/
def read (lines : List String) : List Rule := lines.filterMap parse

/-- **Nothing lost.** A line that is not Lin Flow's own and not a rule line is in the saved file. -/
theorem keeps_every_other_line (rules : List Rule) (existing : List String) (l : String)
    (hl : l ∈ existing) (hown : own l = false) (hp : ruleLike l = false) :
    l ∈ save render own ruleLike header keptHeader rules existing := by
  unfold save
  have hk : l ∈ kept own ruleLike existing := by
    simp [kept, List.mem_filter, hl, hown, hp]
  split
  · rename_i he; rw [he] at hk; cases hk
  · simp [hk]

theorem read_kept (existing : List String) (hn : ∀ l, ruleLike l = false → parse l = none) :
    read parse (kept own ruleLike existing) = [] := by
  simp only [read, kept, List.filterMap_eq_nil_iff, List.mem_filter, Bool.and_eq_true,
    Bool.not_eq_true']
  intro a ha
  exact hn a ha.2.2

/-- **Read back as saved.** -/
theorem reads_back_as_saved (rules : List Rule) (existing : List String)
    (hr : ∀ r ∈ rules, parse (render r) = some r)
    (hh : parse header = none) (hk : parse keptHeader = none)
    (hn : ∀ l, ruleLike l = false → parse l = none) :
    read parse (save render own ruleLike header keptHeader rules existing) = rules := by
  have hmap : (rules.map render).filterMap parse = rules := by
    induction rules with
    | nil => rfl
    | cons r rs ih =>
      simp only [List.map_cons, List.filterMap_cons, hr r (by simp)]
      rw [ih (fun r' h' => hr r' (by simp [h']))]
  have hkept := read_kept parse own ruleLike existing hn
  unfold save read
  split
  · simp [hh, hmap]
  · simp only [read] at hkept
    simp [hh, hk, List.filterMap_append, hmap, hkept]

end LinFlow.Dictionary
