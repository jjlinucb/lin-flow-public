import { describe, expect, it } from "vitest";
import { saveEdit, type RuleEdit } from "./api";

const edit = (kind: RuleEdit["kind"], from: string, to: string): RuleEdit => ({ kind, original: "jaz mint", from, to });

describe("saveEdit", () => {
  it("rewrites a correction under the left side it was opened with", () => {
    expect(saveEdit(edit("rule", " Jazz Mint ", "Jasmine "))).toEqual(["edit_rule", { original: "jaz mint", from: "Jazz Mint", to: "Jasmine" }]);
  });

  it("adds a suggestion as edited, naming the one it came from", () => {
    expect(saveEdit(edit("pending", "jaz mint", "Jasmine"))).toEqual(["accept_rule", { original: "jaz mint", from: "jaz mint", to: "Jasmine" }]);
  });

  it("sends nothing while either side is blank", () => {
    expect(saveEdit(edit("rule", "  ", "Jasmine"))).toBeNull();
    expect(saveEdit(edit("pending", "jaz mint", ""))).toBeNull();
  });
});
