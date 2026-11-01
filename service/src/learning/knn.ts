// Recency-weighted kNN over the owner's past decisions (research R4).
import { cosine } from "../llm/client.js";
import type { FewShot } from "../suggest/prompt.js";
import type { Retrieval, RetrievalInput, Retriever } from "../suggest/retriever.js";
import type { ExampleIndex, IndexEntry } from "./index.js";

const DAY_MS = 86_400_000;

/** 0.5^(age_days / half_life) */
export function recencyWeight(ageDays: number, halfLifeDays: number): number {
  return Math.pow(0.5, Math.max(0, ageDays) / halfLifeDays);
}

export interface KnnOptions {
  neighbours: number;
  fewShotExamples: number;
  recencyHalfLifeDays: number;
  minSimilarity: number;
  /** Current embedding model; examples embedded with another model are skipped. */
  embeddingModel: () => string;
}

/** Category id → current key/path (follows renames and moves). */
export type CategoryLookup = (setId: string) => Map<string, { key: string; path: string }>;

export class KnnRetriever implements Retriever {
  constructor(
    private readonly index: ExampleIndex,
    private readonly categoriesOf: CategoryLookup,
    private readonly opts: KnnOptions,
    private readonly now: () => number = Date.now,
  ) {}

  retrieve(input: RetrievalInput): Retrieval {
    const cats = this.categoriesOf(input.setId);
    const candidateKeys = new Set(input.candidates.map((c) => c.key));
    const model = this.opts.embeddingModel();
    const scored: { e: IndexEntry; key: string; path: string; sim: number }[] = [];
    for (const e of this.index.forSet(input.setId)) {
      if (e.userId !== input.userId || e.embeddingModel !== model) continue;
      const cat = cats.get(e.categoryId);
      if (!cat || !candidateKeys.has(cat.key)) continue;
      const sim = cosine(input.embedding, e.embedding);
      if (sim < this.opts.minSimilarity) continue;
      scored.push({ e, key: cat.key, path: cat.path, sim });
    }
    scored.sort((a, b) => b.sim - a.sim || b.e.decidedAt - a.e.decidedAt);
    const top = scored.slice(0, this.opts.neighbours);

    const votes = new Map<string, number>();
    const now = this.now();
    for (const n of top) {
      const w =
        n.sim * recencyWeight((now - n.e.decidedAt) / DAY_MS, this.opts.recencyHalfLifeDays);
      votes.set(n.key, (votes.get(n.key) ?? 0) + w);
      const slash = n.key.indexOf("/");
      if (slash > 0) {
        const parent = n.key.slice(0, slash);
        if (candidateKeys.has(parent)) votes.set(parent, (votes.get(parent) ?? 0) + w / 2);
      }
    }
    const examples: FewShot[] = top.slice(0, this.opts.fewShotExamples).map((n) => ({
      sender: n.e.sender,
      subject: n.e.subject,
      snippet: n.e.snippet.slice(0, 300),
      path: n.path,
    }));
    return { votes, examples, count: top.length };
  }
}
