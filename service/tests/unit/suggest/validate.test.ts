import { describe, expect, it } from "vitest";
import { dedupeCandidates } from "../../../src/categories/path.js";
import { validateOutput } from "../../../src/suggest/validate.js";
import { computeConfidence } from "../../../src/suggest/confidence.js";
import { l2normalise } from "../../../src/llm/client.js";
import { stubEmbedding } from "../../helpers/stub-llm.js";

const candidates = dedupeCandidates([
  "Family",
  "Family/Baby",
  "Gadgets",
  "Travelling",
  "Travelling/TripXYZ",
]);
const embed = async (names: string[]) =>
  names.map((n) => l2normalise(Float32Array.from(stubEmbedding(n))));
const opts = { nameEmbeddings: embed, duplicateSimilarity: 0.9 };

describe("validateOutput", () => {
  it("maps an existing category case-insensitively", async () => {
    const v = await validateOutput(
      {
        isNew: false,
        category: "family/baby",
        confidence: "high",
        reason: "r",
        ranking: ["family", "Nope"],
      },
      candidates,
      opts,
    );
    expect(v.category).toBe("Family/Baby");
    expect(v.isNew).toBe(false);
    expect(v.forcedLow).toBe(false);
    expect(v.ranking.map((c) => c.path)).toEqual(["Family"]);
  });

  it("rejects a category not in the candidates and falls back to the best valid ranking entry, forced low", async () => {
    const v = await validateOutput(
      {
        isNew: false,
        category: "Finance",
        confidence: "high",
        reason: "r",
        ranking: ["Unknown", "Gadgets", "Family"],
      },
      candidates,
      opts,
    );
    expect(v.category).toBe("Gadgets");
    expect(v.forcedLow).toBe(true);
    expect(v.ranking.map((c) => c.path)).toEqual(["Family"]);
  });

  it("rejects output that does not match the schema", async () => {
    await expect(validateOutput({ category: "Family" }, candidates, opts)).rejects.toThrow();
    await expect(validateOutput("Family", candidates, opts)).rejects.toThrow();
  });

  it("nulls a new-category parent that is not an existing top-level candidate", async () => {
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: "Holidays", name: "Lisbon" },
        confidence: "medium",
        reason: "r",
        ranking: [],
      },
      candidates,
      opts,
    );
    expect(v.isNew).toBe(true);
    expect(v.newCategory).toEqual({ parent: null, name: "Lisbon" });
    expect(v.category).toBe("Lisbon");
  });

  it("does not allow a subcategory as the parent (max depth 2)", async () => {
    // The schema pattern forbids "/" in a parent, so a three-level proposal never gets through.
    await expect(
      validateOutput(
        {
          isNew: true,
          newCategory: { parent: "Family/Baby", name: "Clothes" },
          confidence: "medium",
          reason: "r",
          ranking: [],
        },
        candidates,
        opts,
      ),
    ).rejects.toThrow();
    // A parent that is itself a subcategory name (without the slash) is not a top-level candidate.
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: "Baby", name: "Clothes" },
        confidence: "medium",
        reason: "r",
        ranking: [],
      },
      candidates,
      opts,
    );
    expect(v.newCategory?.parent).toBeNull();
  });

  it("keeps a valid new subcategory under an existing parent, using the parent's casing", async () => {
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: "travelling", name: "Trip Lisbon" },
        confidence: "medium",
        reason: "r",
        ranking: ["Travelling"],
      },
      candidates,
      opts,
    );
    expect(v.newCategory).toEqual({ parent: "Travelling", name: "Trip Lisbon" });
    expect(v.category).toBe("Travelling/Trip Lisbon");
  });

  it("replaces a near-duplicate proposal by name ('Gadget' vs 'Gadgets')", async () => {
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: null, name: "Gadget" },
        confidence: "medium",
        reason: "r",
        ranking: [],
      },
      candidates,
      opts,
    );
    expect(v.isNew).toBe(false);
    expect(v.category).toBe("Gadgets");
  });

  it("replaces a proposal that equals an existing path", async () => {
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: "Family", name: "baby" },
        confidence: "medium",
        reason: "r",
        ranking: [],
      },
      candidates,
      opts,
    );
    expect(v.isNew).toBe(false);
    expect(v.category).toBe("Family/Baby");
  });

  it("replaces a proposal whose name embedding is >= the duplicate threshold", async () => {
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: "Travelling", name: "TripXYZ trip" },
        confidence: "medium",
        reason: "r",
        ranking: [],
      },
      candidates,
      {
        ...opts,
        nameEmbeddings: async (names: string[]) =>
          names.map(() => l2normalise(Float32Array.from([1, 0, 0]))),
      },
    );
    expect(v.isNew).toBe(false);
    expect(v.category).toBe("Travelling/TripXYZ");
  });

  it("keeps a proposal whose name is not similar", async () => {
    const v = await validateOutput(
      {
        isNew: true,
        newCategory: { parent: null, name: "Health" },
        confidence: "low",
        reason: "r",
        ranking: [],
      },
      candidates,
      opts,
    );
    expect(v.isNew).toBe(true);
  });

  it("treats a category answer with no candidates as a new top-level proposal", async () => {
    const v = await validateOutput(
      { isNew: false, category: "Personal", confidence: "low", reason: "r", ranking: [] },
      [],
      opts,
    );
    expect(v.isNew).toBe(true);
    expect(v.newCategory).toEqual({ parent: null, name: "Personal" });
  });
});

describe("computeConfidence (research R6)", () => {
  const base = { chosenKey: "family", isNew: false, forcedLow: false, agreeShare: 0.6 };

  it("high when the LLM says high and there are no examples", () => {
    expect(computeConfidence({ ...base, llmConfidence: "high", knn: null })).toBe("high");
    expect(
      computeConfidence({ ...base, llmConfidence: "high", knn: { votes: new Map(), count: 0 } }),
    ).toBe("high");
  });

  it("medium when the LLM says medium and there are no examples", () => {
    expect(computeConfidence({ ...base, llmConfidence: "medium", knn: null })).toBe("medium");
  });

  it("low for a new proposal, a low LLM answer or a forced fallback", () => {
    expect(computeConfidence({ ...base, isNew: true, llmConfidence: "high", knn: null })).toBe(
      "low",
    );
    expect(computeConfidence({ ...base, llmConfidence: "low", knn: null })).toBe("low");
    expect(computeConfidence({ ...base, forcedLow: true, llmConfidence: "high", knn: null })).toBe(
      "low",
    );
  });

  it("high when kNN agrees with share >= 0.6, low when it disagrees with share >= 0.6", () => {
    const agree = {
      votes: new Map([
        ["family", 3],
        ["gadgets", 1],
      ]),
      count: 4,
    };
    const disagree = {
      votes: new Map([
        ["gadgets", 3],
        ["family", 1],
      ]),
      count: 4,
    };
    expect(computeConfidence({ ...base, llmConfidence: "medium", knn: agree })).toBe("high");
    expect(computeConfidence({ ...base, llmConfidence: "high", knn: disagree })).toBe("low");
  });

  it("medium when kNN is split", () => {
    const split = {
      votes: new Map([
        ["family", 1],
        ["gadgets", 1],
      ]),
      count: 2,
    };
    expect(computeConfidence({ ...base, llmConfidence: "high", knn: split })).toBe("medium");
  });
});
