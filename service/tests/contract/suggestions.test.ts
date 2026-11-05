// Contract: specs/001-local-llm-categorizer/contracts/http-api.md — POST /v1/suggestions
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { startTestApp, type TestApp } from "../helpers/app.js";
import { keywordChat } from "../helpers/keyword-chat.js";

const FIXTURES = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../fixtures/synthetic/examples",
);
const fixture = (name: string) =>
  JSON.parse(fs.readFileSync(path.join(FIXTURES, `${name}.json`), "utf8"));

interface Suggestion {
  suggestionId: string;
  category: string;
  isNew: boolean;
  newCategory?: { parent: string | null; name: string };
  confidence: string;
  reason: string;
  runnersUp: { path: string; score: number }[];
  similarPastDecisions: number;
  truncated: boolean;
  expiresAt: string;
}

let t: TestApp;

beforeAll(async () => {
  t = await startTestApp();
});
afterAll(async () => t.close());
beforeEach(() => {
  t.stub.setDown(false);
  t.stub.setCompletionError(null);
  t.stub.setChat(keywordChat);
});

const suggest = (body: unknown) =>
  t.call<Suggestion & { error: { code: string; message: string } }>(
    "POST",
    "/v1/suggestions",
    body,
  );

describe("POST /v1/suggestions", () => {
  it("returns a Suggestion matching the contract (V1: family)", async () => {
    const f = fixture("dad-lunch");
    const res = await suggest({ email: f.email, categories: f.categories });
    expect(res.status).toBe(200);
    const s = res.body;
    expect(s.suggestionId).toMatch(/^[0-9A-Z]{26}$/);
    expect(s.category).toBe("Family");
    expect(s.isNew).toBe(false);
    expect(s.newCategory).toBeUndefined();
    expect(["high", "medium", "low"]).toContain(s.confidence);
    expect(typeof s.reason).toBe("string");
    expect(s.runnersUp.length).toBeLessThanOrEqual(5);
    for (const r of s.runnersUp) {
      expect(f.categories).toContain(r.path);
      expect(r.path).not.toBe(s.category);
      expect(r.score).toBeGreaterThanOrEqual(0);
      expect(r.score).toBeLessThanOrEqual(1);
    }
    expect(s.similarPastDecisions).toBe(0);
    expect(s.truncated).toBe(false);
    expect(Date.parse(s.expiresAt)).toBeGreaterThan(Date.now());
  });

  it("V1: gadgets", async () => {
    const f = fixture("apple-launch");
    const res = await suggest({ email: f.email, categories: f.categories });
    expect(res.body.category).toBe("Gadgets");
  });

  it("V2: prefers the subcategory", async () => {
    const f = fixture("newborn-checkup");
    const res = await suggest({ email: f.email, categories: f.categories });
    expect(res.body.category).toBe("Family/Baby");
  });

  it("V3: proposes a new subcategory, marked new and low confidence", async () => {
    const f = fixture("new-trip-booking");
    const res = await suggest({ email: f.email, categories: f.categories });
    expect(res.status).toBe(200);
    expect(res.body.isNew).toBe(true);
    expect(res.body.newCategory?.parent).toBe("Travelling");
    expect(res.body.category).toBe(`Travelling/${res.body.newCategory?.name}`);
    expect(res.body.confidence).toBe("low");
    expect(res.body.runnersUp.length).toBeGreaterThan(0);
  });

  it("accepts a saved set by categorySetId", async () => {
    const sets = await t.call<{ id: string; isDefault: boolean }[]>("GET", "/v1/category-sets");
    // US3 adds this endpoint; until then the default set id is looked up directly.
    const setId =
      sets.status === 200
        ? sets.body.find((s) => s.isDefault)!.id
        : t.app.ctx.categories.getOrCreateDefaultSet("owner").id;
    t.app.ctx.categories.upsertPath(setId, "Family");
    t.app.ctx.categories.upsertPath(setId, "Gadgets");
    const res = await suggest({ email: fixture("dad-lunch").email, categorySetId: setId });
    expect(res.status).toBe(200);
    expect(res.body.category).toBe("Family");
  });

  it("allows an empty category list (new top-level proposal only)", async () => {
    const res = await suggest({ email: fixture("dad-lunch").email, categories: [] });
    expect(res.status).toBe(200);
    expect(res.body.isNew).toBe(true);
    expect(res.body.newCategory?.parent).toBeNull();
  });

  it("flags truncation for very long emails", async () => {
    const email = { ...fixture("dad-lunch").email, body: "family gathering words ".repeat(2000) };
    const res = await suggest({ email, categories: ["Family", "Gadgets"] });
    expect(res.status).toBe(200);
    expect(res.body.truncated).toBe(true);
  });

  describe("400 invalid_request", () => {
    const email = {
      from: "x@example.test",
      subject: "SYNTHETIC-SUBJECT-400",
      body: "SYNTHETIC-BODY-400",
    };
    const cases: [string, unknown][] = [
      ["path deeper than two levels", { email, categories: ["Family/Baby/Clothes"] }],
      [
        "both categories and categorySetId",
        { email, categories: ["Family"], categorySetId: "01H00000000000000000000000" },
      ],
      ["neither categories nor categorySetId", { email }],
      [
        "empty subject and body",
        { email: { from: "x@example.test", subject: "  ", body: "\n" }, categories: ["Family"] },
      ],
      ["missing email", { categories: ["Family"] }],
    ];
    for (const [name, body] of cases) {
      it(name, async () => {
        const res = await suggest(body);
        expect(res.status).toBe(400);
        expect(res.body.error.code).toBe("invalid_request");
        expect(JSON.stringify(res.body)).not.toContain("SYNTHETIC-SUBJECT-400");
        expect(JSON.stringify(res.body)).not.toContain("SYNTHETIC-BODY-400");
      });
    }
  });

  it("404 for an unknown categorySetId", async () => {
    const res = await suggest({
      email: fixture("dad-lunch").email,
      categorySetId: "01H00000000000000000000000",
    });
    expect(res.status).toBe(404);
  });

  it("503 llm_unavailable when the local runtime is down, without echoing content", async () => {
    t.stub.setDown(true);
    const f = fixture("dad-lunch");
    const res = await suggest({ email: f.email, categories: f.categories });
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe("llm_unavailable");
    expect(JSON.stringify(res.body)).not.toContain("Grandma");
  });

  it("says the answer was unusable, not that the model is down, when the runtime errors", async () => {
    t.stub.setCompletionError(500);
    const f = fixture("dad-lunch");
    const res = await suggest({ email: f.email, categories: f.categories });
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe("llm_unavailable");
    expect(res.body.error.message).toMatch(/unusable answer/);
  });
});
