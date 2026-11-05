// The grammar copy of the suggestion schema must not let a name swallow the closing quote, or
// llama.cpp stops generating mid-JSON (seen with Qwen3 on prompt-injection emails).
import { describe, expect, it } from "vitest";
import { llmResponseSchema, llmSuggestionSchema } from "../../src/llm/schema.js";

const patterns = (o: unknown): string[] =>
  JSON.stringify(o)
    .match(/"pattern":"((?:[^"\\]|\\.)*)"/g)
    ?.map((m) => JSON.parse(`{${m}}`).pattern) ?? [];

describe("llm grammar schema", () => {
  it("keeps every pattern but excludes the double quote from name characters", () => {
    const grammar = patterns(llmResponseSchema);
    expect(grammar.length).toBe(patterns(llmSuggestionSchema).length);
    for (const p of grammar) {
      expect(new RegExp(p).test("Family")).toBe(true);
      expect(new RegExp(p).test('Fam"ily')).toBe(false);
    }
  });
});
