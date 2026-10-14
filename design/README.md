# Design reference — the Mac app, for the Windows port to copy

`mac/` is five screenshots of `/Applications/Lin Flow.app`, one per sidebar section, taken
2026-09-19 from the running signed build at 1027x882 pt on a 2x display (so the PNGs are
2054x1764 and every measurement below is the pixel value halved).

**Capture them with the window active.** The first pass here was taken while Chrome was
frontmost and macOS drew the whole window in its inactive style: grey traffic lights, grey
sidebar icons, grey labels. That is not the app's look, and a port built from it would come out
colorless — the sidebar icons are *blue*. `open -a "/Applications/Lin Flow.app"` first, capture,
then hand focus back to whatever had it.

**Two of the seven are not here.** `01-dictation.png` and `03-dictionary.png` showed a real
dictation history and dictionary, so they are not published. Retake them from the recipe below
against a throwaway data folder (`LINFLOW_DATA_DIR`) if you need them.

How these were made, for the next pass:

```bash
swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/probes/winshot.swift -o /tmp/winshot
swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/probes/axdrive.swift -o /tmp/axdrive
/tmp/axdrive select $(pgrep -f "Lin Flow.app") Dictionary    # switch section
/tmp/winshot $(pgrep -f "Lin Flow.app") design/mac/03-dictionary.png "Lin Flow"
```

`axdrive select` drives the running app, so point it at a test instance rather than the copy
you dictate with, and put it back on Dictation afterwards.

## Tokens, sampled from the pixels

| Token | Value | Where |
|---|---|---|
| Sidebar background | `#EDEDEC` | behind the section list |
| Sidebar selected row | `#D7D7D6` | rounded pill behind the current section |
| Content background | `#FFFFFF` | everything right of the sidebar |
| Text primary | `#272727` | headers, list rows |
| Text on sidebar | `#000000` | section labels, selected and not |
| Text secondary | `#808080` | the description under a header, footnotes |
| Separator | `#E6E6E6` | 1pt hairline between list rows |
| Separator (settings) | `#EBEBEB` | between rows inside a settings group |
| Accent | `#007AFF` | sidebar icons, selected-card border, checkmarks |
| Example block | `#F3F3F3` | the sample text inside a Style card, Try-it boxes |
| Badge fill | `#E6E6E6` | the "learned" pill |

Note the sidebar icons are accent blue whether or not their row is selected; selection is carried
by the pill and by the label going semibold, not by the icon color.

## Metrics

| Thing | Size |
|---|---|
| Window | 1027 x 882 pt, min ~640 x 420 |
| Sidebar width | 190 pt |
| Sidebar row height | 32 pt |
| Sidebar pill | inset 10 pt each side (170 pt wide), ~7 pt corner radius |
| Sidebar icon | at x 22 pt, label at x 47 pt |
| Content left margin | 212 pt from the window edge — 22 pt in from the sidebar |
| Content top padding | 48 pt (the macOS 26 glass zone; see CLAUDE.md) |
| List row (words) | 24.5 pt pitch |
| List row (corrections) | 27 pt pitch |
| Hairline | 1 pt |

## Type

macOS sizes are points at 1x, which are device-independent pixels. Windows `Font` sizes are
points at 96 dpi, so **multiply by 0.75** to get the same number of logical pixels, and lay the
boxes out 1:1 (a 190 pt Mac sidebar is a 190 logical-pixel Windows sidebar, then through `Ui.S`).

| Role | macOS | Windows equivalent |
|---|---|---|
| Section header ("Words", "Auto cleanup") | 17 semibold | Segoe UI Semibold 12.75 |
| Description under a header | 13 regular, `#808080` | Segoe UI 9.75 |
| List row text | 13 regular | Segoe UI 9.75 |
| Sidebar label | 13 (semibold when selected) | Segoe UI 9.75 |
| Titlebar name / section | 13 bold / 11 regular | Segoe UI Bold 9.75 / 8.25 |
| Badge | 11 | Segoe UI 8.25 |

## The seven pages

| # | Section | Shape | Windows |
|---|---|---|---|
| 1 | Dictation | stats strip (total words, wpm, streak) + search, then dictations grouped under Today / Yesterday / a date, each row with per-row actions | yes — history exists |
| 2 | Notetaker | three columns: sidebar, meeting list with "+ New", detail or an empty state | yes — `NotetakerTab` |
| 3 | Dictionary | two columns: Words and Corrections, each an add-row then a hairline list; learned rules carry a grey "learned" badge and sort newest first | yes |
| 4 | Snippets | header, a "New snippet" card with trigger + body, then the list or an empty state | **no Core support** |
| 5 | Style | three selectable cards (None / Light / Medium), selected one gets a 2 pt accent border and a filled accent checkmark; then a "By app" section | **no Core support** |
| 6 | Transforms | three columns: sidebar, transform list with "+ New", detail with Instructions and a Try-it box | **no Core support** |
| 7 | Settings | grouped inset list: a bold group title, then a rounded card of rows, label left and control right, with grey footnote paragraphs between groups | yes |

Snippets, Style and Transforms have no counterpart in `LinFlow.Core` — there is no `Snippets.cs`,
no transform runner and no rewriter on the Windows side. They are not in the ported sidebar,
because a section that cannot do anything is worse than an absent one. Style and Transforms would
both need the rewrite path that Ollama already provides for running notes; Snippets is
self-contained and would be the cheapest of the three to add.

## Patterns worth copying exactly

- **Empty states are centered**: a large grey glyph, a bold line, then a grey sentence saying what
  to do next ("No meeting selected / Click New, then Start recording when the meeting begins.").
- **A header is always followed by a grey sentence** explaining the section in plain language.
  Every page does this; it is most of why the app reads as finished.
- **Destructive actions are a grey trash glyph at the right end of the row**, never a button.
- **Add rows sit above the list they add to**, as a text field plus a disabled-until-valid Add
  button.
- **Buttons are grey rounded rects with no border**; the accent color is reserved for selection
  and icons.

## What the Windows port does with this

As of 2026-09-19 the Windows window follows this reference: `windows/LinFlow.App/Mac.cs` holds
the tokens above as code, `MacControls.cs` holds the painted controls, and `Dashboard.cs` is the
sidebar shell. The four sections it has are Dictation, Notetaker, Dictionary and Settings.

It compiles and the 537 tests pass, both on the Mac — **and no part of it has ever drawn a
pixel.** WinForms layout is exactly where this port has gone wrong before. When comparing on a
real machine, go page by page against `mac/` and look first at the sidebar glyphs (they need
Segoe Fluent Icons or Segoe MDL2 Assets) and at 200% scaling. `windows/NOTES.md` has the longer
list under "The Mac's look, ported".
