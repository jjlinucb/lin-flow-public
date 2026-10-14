import { describe, expect, it } from "vitest";
import type { VNode } from "preact";
import { blocks, inline } from "./markdown";

// A rendered piece as plain data: text stays text, an element becomes [tag, text, title?].
const shape = (parts: unknown[]) =>
  parts.map((p) => {
    if (typeof p === "string") return p;
    const v = p as VNode<{ children: string; title?: string }>;
    return v.props.title ? [v.type, v.props.children, v.props.title] : [v.type, v.props.children];
  });

describe("blocks", () => {
  it("reads headings, bullets, rules and paragraphs line by line", () => {
    const text = "## Summary\n* one\n- two\n• three\n\n---\nPlain line.\n### Action items";
    expect(blocks(text)).toEqual([
      { kind: "heading", text: "Summary" },
      { kind: "bullet", text: "one" },
      { kind: "bullet", text: "two" },
      { kind: "bullet", text: "three" },
      { kind: "rule" },
      { kind: "paragraph", text: "Plain line." },
      { kind: "heading", text: "Action items" },
    ]);
  });

  it("trims each line and skips blank ones", () => {
    expect(blocks("   \n  * indented  \n\n\t## Spaced \n")).toEqual([
      { kind: "bullet", text: "indented" },
      { kind: "heading", text: "Spaced" },
    ]);
  });

  it("needs a space after a bullet mark, as the Mac does", () => {
    expect(blocks("*emphasis* first\n-5 degrees")).toEqual([
      { kind: "paragraph", text: "*emphasis* first" },
      { kind: "paragraph", text: "-5 degrees" },
    ]);
  });

  it("reads Windows line endings too", () => {
    expect(blocks("## A\r\n* b\r\n")).toEqual([
      { kind: "heading", text: "A" },
      { kind: "bullet", text: "b" },
    ]);
  });
});

describe("inline", () => {
  it("leaves plain text alone", () => {
    expect(shape(inline("Nothing to see here."))).toEqual(["Nothing to see here."]);
  });

  it("marks bold, italics, strikethrough and code in order", () => {
    expect(shape(inline("**Ship** it *now*, not ~~later~~, with `fleet.sh`."))).toEqual([
      ["strong", "Ship"],
      " it ",
      ["em", "now"],
      ", not ",
      ["s", "later"],
      ", with ",
      ["code", "fleet.sh"],
      ".",
    ]);
  });

  it("reads _underscores_ as italics only at word edges", () => {
    expect(shape(inline("an _aside_ here"))).toEqual(["an ", ["em", "aside"], " here"]);
    expect(shape(inline("kept as transcript_live_copy.jsonl"))).toEqual(["kept as transcript_live_copy.jsonl"]);
  });

  it("shows a link's text and keeps the address for hovering", () => {
    expect(shape(inline("See [the notes](https://example.com/a) first."))).toEqual([
      "See ",
      ["span", "the notes", "https://example.com/a"],
      " first.",
    ]);
  });

  it("leaves an unclosed mark as text", () => {
    expect(shape(inline("**half bold and a lone * star"))).toEqual(["**half bold and a lone * star"]);
  });
});
