// Ajv validator for the LLM output contract (contracts/llm-suggestion.schema.json, copied here).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

export type LlmConfidence = "high" | "medium" | "low";

export interface LlmSuggestion {
  isNew: boolean;
  category?: string;
  newCategory?: { parent: string | null; name: string };
  confidence: LlmConfidence;
  reason: string;
  ranking: string[];
}

const SCHEMA_FILE = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "llm-suggestion.schema.json",
);

/** The JSON schema object, also sent to the runtime as the response_format grammar. */
export const llmSuggestionSchema: Record<string, unknown> = JSON.parse(
  fs.readFileSync(SCHEMA_FILE, "utf8"),
);

// The runtime grammar does not need $id/$schema/descriptions, and llama.cpp's schema-to-grammar
// converter does not support if/then; the conditional rules are enforced by Ajv afterwards.
export const llmResponseSchema: Record<string, unknown> = (() => {
  const {
    $schema: _s,
    $id: _i,
    title: _t,
    description: _d,
    allOf: _a,
    ...rest
  } = llmSuggestionSchema;
  return rest;
})();

const ajv = new Ajv2020.default({ allErrors: false, strict: false });
export const isLlmSuggestion = ajv.compile<LlmSuggestion>(llmSuggestionSchema);
