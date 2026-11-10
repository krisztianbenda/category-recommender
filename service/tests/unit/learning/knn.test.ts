import { describe, expect, it } from "vitest";
import { dedupeCandidates } from "../../../src/categories/path.js";
import { ExampleIndex, type IndexEntry } from "../../../src/learning/index.js";
import { KnnRetriever, recencyWeight } from "../../../src/learning/knn.js";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 30);

const v = (...xs: number[]) => {
  const n = Math.hypot(...xs);
  return Float32Array.from(xs.map((x) => x / n));
};

const CATS = new Map([
  ["c-family", { key: "family", path: "Family" }],
  ["c-baby", { key: "family/baby", path: "Family/Baby" }],
  ["c-finance", { key: "finance", path: "Finance" }],
  ["c-gadgets", { key: "gadgets", path: "Gadgets" }],
]);

let n = 0;
function entry(
  categoryId: string | null,
  embedding: Float32Array,
  ageDays = 0,
  extra: Partial<IndexEntry> = {},
): IndexEntry {
  n++;
  return {
    id: `e${n}`,
    userId: "owner",
    setId: "set1",
    categoryId,
    embedding,
    embeddingModel: "m",
    decidedAt: NOW - ageDays * DAY,
    sender: `sender ${n}`,
    subject: `subject ${n}`,
    snippet: "x".repeat(600),
    ...extra,
  };
}

function retriever(
  entries: IndexEntry[],
  opts: Partial<ConstructorParameters<typeof KnnRetriever>[2]> = {},
) {
  const index = new ExampleIndex();
  index.load(entries);
  return new KnnRetriever(
    index,
    () => CATS,
    {
      neighbours: 8,
      fewShotExamples: 5,
      recencyHalfLifeDays: 180,
      minSimilarity: 0.5,
      embeddingModel: () => "m",
      ...opts,
    },
    () => NOW,
  );
}

const candidates = dedupeCandidates(["Family", "Family/Baby", "Finance", "Gadgets"]);
const q = v(1, 0, 0);

describe("recency weight", () => {
  it("halves every half-life", () => {
    expect(recencyWeight(0, 180)).toBe(1);
    expect(recencyWeight(180, 180)).toBeCloseTo(0.5);
    expect(recencyWeight(360, 180)).toBeCloseTo(0.25);
  });
});

describe("KnnRetriever", () => {
  it("votes similarity × recency per category", () => {
    const r = retriever([
      entry("c-finance", v(1, 0, 0), 0),
      entry("c-finance", v(1, 0, 0), 180),
      entry("c-gadgets", v(0.8, 0.6, 0)),
    ]);
    const out = r.retrieve({ userId: "owner", setId: "set1", embedding: q, candidates });
    expect(out.votes.get("finance")).toBeCloseTo(1 + 0.5);
    expect(out.votes.get("gadgets")).toBeCloseTo(0.8);
    expect(out.count).toBe(3);
  });

  it("adds half a vote to the parent of a subcategory", () => {
    const r = retriever([entry("c-baby", v(1, 0, 0))]);
    const out = r.retrieve({ userId: "owner", setId: "set1", embedding: q, candidates });
    expect(out.votes.get("family/baby")).toBeCloseTo(1);
    expect(out.votes.get("family")).toBeCloseTo(0.5);
  });

  it("only counts examples whose category is a candidate", () => {
    const r = retriever([entry("c-finance", v(1, 0, 0)), entry("c-gadgets", v(1, 0, 0))]);
    const out = r.retrieve({
      userId: "owner",
      setId: "set1",
      embedding: q,
      candidates: dedupeCandidates(["Gadgets"]),
    });
    expect([...out.votes.keys()]).toEqual(["gadgets"]);
    expect(out.count).toBe(1);
  });

  it("ignores neighbours below the similarity floor, other users, other sets and stale models", () => {
    const r = retriever([
      entry("c-finance", v(0.3, 0.95, 0)),
      entry("c-finance", v(1, 0, 0), 0, { userId: "someone-else" }),
      entry("c-finance", v(1, 0, 0), 0, { setId: "set2" }),
      entry("c-finance", v(1, 0, 0), 0, { embeddingModel: "old" }),
    ]);
    const out = r.retrieve({ userId: "owner", setId: "set1", embedding: q, candidates });
    expect(out.count).toBe(0);
    expect(out.votes.size).toBe(0);
  });

  it("uses at most k neighbours, nearest first", () => {
    const entries = Array.from({ length: 12 }, (_, i) => entry("c-gadgets", v(1, i * 0.05, 0)));
    const out = retriever(entries, { neighbours: 4 }).retrieve({
      userId: "owner",
      setId: "set1",
      embedding: q,
      candidates,
    });
    expect(out.count).toBe(4);
  });

  it("returns the top few-shot examples with snippets cut to 300 chars", () => {
    const entries = Array.from({ length: 8 }, (_, i) =>
      entry(i % 2 ? "c-family" : "c-finance", v(1, i * 0.1, 0)),
    );
    const out = retriever(entries).retrieve({
      userId: "owner",
      setId: "set1",
      embedding: q,
      candidates,
    });
    expect(out.examples).toHaveLength(5);
    expect(out.examples[0]!.subject).toBe(entries[0]!.subject);
    for (const e of out.examples) expect(e.snippet.length).toBeLessThanOrEqual(300);
    expect(out.examples[0]!.path).toBe("Finance");
  });

  it("counts deleted emails apart from the category votes, and never as few-shot examples", () => {
    const r = retriever([
      entry(null, v(1, 0, 0), 0),
      entry(null, v(1, 0, 0), 180),
      entry("c-finance", v(0.8, 0.6, 0)),
    ]);
    const out = r.retrieve({ userId: "owner", setId: "set1", embedding: q, candidates });
    expect(out.deleted.count).toBe(2);
    expect(out.deleted.vote).toBeCloseTo(1 + 0.5);
    expect(out.filedVote).toBeCloseTo(0.8);
    expect([...out.votes.keys()]).toEqual(["finance"]);
    expect(out.count).toBe(3);
    expect(out.examples.map((e) => e.path)).toEqual(["Finance"]);
  });

  it("lets deleted emails take the nearest places from filed ones", () => {
    const out = retriever(
      [
        entry(null, v(1, 0, 0)),
        entry(null, v(1, 0.05, 0)),
        entry("c-gadgets", v(1, 0.5, 0)),
        entry("c-gadgets", v(1, 0.6, 0)),
      ],
      { neighbours: 2 },
    ).retrieve({ userId: "owner", setId: "set1", embedding: q, candidates });
    expect(out.deleted.count).toBe(2);
    expect(out.filedVote).toBe(0);
  });

  it("reflects removals immediately", () => {
    const index = new ExampleIndex();
    const e = entry("c-finance", v(1, 0, 0));
    index.load([e]);
    const r = new KnnRetriever(
      index,
      () => CATS,
      {
        neighbours: 8,
        fewShotExamples: 5,
        recencyHalfLifeDays: 180,
        minSimilarity: 0.5,
        embeddingModel: () => "m",
      },
      () => NOW,
    );
    expect(r.retrieve({ userId: "owner", setId: "set1", embedding: q, candidates }).count).toBe(1);
    index.remove(e.id);
    expect(r.retrieve({ userId: "owner", setId: "set1", embedding: q, candidates }).count).toBe(0);
  });
});
