// In-memory embedding index of learning examples (research R4): brute-force cosine search,
// updated synchronously so deletions take effect at once (FR-011, SC-007).
import type { Embedder } from "../llm/client.js";
import type { Logger } from "../logging/logger.js";
import { embeddingText } from "../suggest/pipeline.js";
import type { LearningExampleRepo, StoredExample } from "../store/repos/learning-examples.js";

export interface IndexEntry {
  id: string;
  userId: string;
  setId: string;
  /** null when the owner deleted the email instead of filing it. */
  categoryId: string | null;
  embedding: Float32Array;
  embeddingModel: string;
  /** ms since epoch */
  decidedAt: number;
  sender: string;
  subject: string;
  snippet: string;
}

export function toEntry(e: StoredExample): IndexEntry {
  return {
    id: e.id,
    userId: e.userId,
    setId: e.setId,
    categoryId: e.categoryId,
    embedding: e.embedding,
    embeddingModel: e.embeddingModel,
    decidedAt: Date.parse(e.decidedAt),
    sender: e.sender,
    subject: e.subject,
    snippet: e.snippet,
  };
}

export class ExampleIndex {
  private readonly bySet = new Map<string, Map<string, IndexEntry>>();
  private readonly setOf = new Map<string, string>();

  load(entries: IndexEntry[]): void {
    for (const e of entries) this.add(e);
  }

  add(e: IndexEntry): void {
    let m = this.bySet.get(e.setId);
    if (!m) this.bySet.set(e.setId, (m = new Map()));
    m.set(e.id, e);
    this.setOf.set(e.id, e.setId);
  }

  remove(id: string): void {
    const setId = this.setOf.get(id);
    if (setId === undefined) return;
    this.bySet.get(setId)?.delete(id);
    this.setOf.delete(id);
  }

  removeWhere(pred: (e: IndexEntry) => boolean): number {
    let n = 0;
    for (const m of this.bySet.values()) {
      for (const e of m.values()) {
        if (pred(e)) {
          m.delete(e.id);
          this.setOf.delete(e.id);
          n++;
        }
      }
    }
    return n;
  }

  removeByCategory(categoryIds: Iterable<string>): number {
    const ids = new Set(categoryIds);
    return this.removeWhere((e) => e.categoryId !== null && ids.has(e.categoryId));
  }

  removeBySet(setId: string): void {
    for (const id of this.bySet.get(setId)?.keys() ?? []) this.setOf.delete(id);
    this.bySet.delete(setId);
  }

  clearUser(userId: string): number {
    return this.removeWhere((e) => e.userId === userId);
  }

  forSet(setId: string): IndexEntry[] {
    return [...(this.bySet.get(setId)?.values() ?? [])];
  }

  get size(): number {
    return this.setOf.size;
  }
}

/**
 * Re-embeds examples stored with a different embedding model (e.g. after switching models or
 * restoring a backup). Examples that cannot be re-embedded stay excluded from retrieval.
 */
export async function reembedStale(
  repo: LearningExampleRepo,
  index: ExampleIndex,
  embedder: Embedder,
  logger: Logger,
): Promise<number> {
  const stale = repo.listByModelMismatch(embedder.model);
  if (stale.length === 0) return 0;
  let done = 0;
  try {
    for (let i = 0; i < stale.length; i += 32) {
      const batch = stale.slice(i, i + 32);
      const vectors = await embedder.embed(
        batch.map((e) => embeddingText({ from: e.sender, subject: e.subject, body: e.snippet })),
      );
      batch.forEach((e, j) => {
        repo.updateEmbedding(e.id, vectors[j]!, embedder.model);
        index.add(toEntry({ ...e, embedding: vectors[j]!, embeddingModel: embedder.model }));
      });
      done += batch.length;
    }
  } catch {
    logger.error(
      { errorCode: "reembed_failed", count: stale.length - done },
      "re-embedding incomplete",
    );
  }
  logger.info({ count: done }, "re-embedded learning examples");
  return done;
}
