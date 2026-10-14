// The summarizer's Markdown, line by line as the Mac's SummaryMarkdown reads it: headings,
// bullets, rules and paragraphs, with bold, italics and code inside a line. Built as elements,
// never as HTML, so nothing a model writes can run in the page.

import type { ComponentChildren } from "preact";

export type Block = { kind: "heading" | "bullet" | "paragraph"; text: string } | { kind: "rule" };

export function blocks(text: string): Block[] {
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0)
    .map((line): Block => {
      if (line.startsWith("#")) return { kind: "heading", text: line.replace(/^#+/, "").trim() };
      if (/^[*\-•] /.test(line)) return { kind: "bullet", text: line.slice(2) };
      if (line === "---") return { kind: "rule" };
      return { kind: "paragraph", text: line };
    });
}

/**
 * **bold**, *italic* or _italic_, ~~struck~~, `code` and [links](url), in order of appearance.
 * As in CommonMark, an underscore inside a word is just an underscore, so transcript_live stays
 * whole. A link shows its text with the address on hover: the page never navigates away.
 */
export function inline(text: string): ComponentChildren[] {
  const out: ComponentChildren[] = [];
  // Each mark hugs its text on both sides, so "a lone * star" stays a star.
  const pattern = /(\*\*[^*\s](?:[^*]*[^*\s])?\*\*|~~[^~\s](?:[^~]*[^~\s])?~~|`[^`]+`|\[[^\]]+\]\([^)\s]+\)|\*[^*\s](?:[^*]*[^*\s])?\*|(?<![\p{L}\p{N}_])_[^_\s](?:[^_]*[^_\s])?_(?![\p{L}\p{N}_]))/gu;
  let last = 0;
  for (const m of text.matchAll(pattern)) {
    const at = m.index ?? 0;
    if (at > last) out.push(text.slice(last, at));
    const token = m[0];
    const link = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(token);
    if (token.startsWith("**")) out.push(<strong>{token.slice(2, -2)}</strong>);
    else if (token.startsWith("~~")) out.push(<s>{token.slice(2, -2)}</s>);
    else if (token.startsWith("`")) out.push(<code>{token.slice(1, -1)}</code>);
    else if (link) out.push(<span class="link-text" title={link[2]}>{link[1]}</span>);
    else out.push(<em>{token.slice(1, -1)}</em>);
    last = at + token.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text }: { text: string }) {
  const items = blocks(text);
  const out: ComponentChildren[] = [];
  let bullets: Block[] = [];
  const flush = () => {
    if (bullets.length) {
      out.push(
        <ul>
          {bullets.map((b) => (
            <li>{"text" in b ? inline(b.text) : null}</li>
          ))}
        </ul>,
      );
      bullets = [];
    }
  };
  for (const b of items) {
    if (b.kind === "bullet") {
      bullets.push(b);
      continue;
    }
    flush();
    if (b.kind === "heading") out.push(<h4>{inline(b.text)}</h4>);
    else if (b.kind === "rule") out.push(<hr />);
    else out.push(<p>{inline(b.text)}</p>);
  }
  flush();
  return <div class="md">{out}</div>;
}
