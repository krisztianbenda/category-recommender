import type { Db } from "../db.js";
import { fromBlob, newId, toBlob } from "../util.js";

/** How a category was chosen, or "deleted" when the owner deleted the email instead. */
export type Outcome = "confirmed" | "corrected" | "accepted_new" | "deleted";

export const SNIPPET_MAX = 600;

export interface NewLearningExample {
  userId: string;
  setId: string;
  /** null exactly when the outcome is "deleted". */
  categoryId: string | null;
  suggestedCategoryPath: string;
  outcome: Outcome;
  sender: string;
  subject: string;
  /** First ≤ 600 chars of the plain-text body. */
  snippet: string;
  embedding: Float32Array;
  embeddingModel: string;
  decidedAt: string;
}

export interface StoredExample {
  id: string;
  userId: string;
  setId: string;
  /** null exactly when the outcome is "deleted". */
  categoryId: string | null;
  outcome: Outcome;
  sender: string;
  subject: string;
  snippet: string;
  embedding: Float32Array;
  embeddingModel: string;
  decidedAt: string;
}

interface Raw {
  id: string;
  user_id: string;
  set_id: string;
  category_id: string | null;
  outcome: Outcome;
  sender: string;
  subject: string;
  snippet: string;
  embedding: Buffer;
  embedding_model: string;
  decided_at: string;
}

const toStored = (r: Raw): StoredExample => ({
  id: r.id,
  userId: r.user_id,
  setId: r.set_id,
  categoryId: r.category_id,
  outcome: r.outcome,
  sender: r.sender,
  subject: r.subject,
  snippet: r.snippet,
  embedding: fromBlob(r.embedding),
  embeddingModel: r.embedding_model,
  decidedAt: r.decided_at,
});

export class LearningExampleRepo {
  constructor(private readonly db: Db) {}

  insert(e: NewLearningExample): string {
    const id = newId();
    this.db
      .prepare(
        `INSERT INTO learning_examples
         (id, user_id, set_id, category_id, suggested_category_path, outcome, sender, subject, snippet, embedding, embedding_model, decided_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        e.userId,
        e.setId,
        e.categoryId,
        e.suggestedCategoryPath,
        e.outcome,
        e.sender,
        e.subject,
        e.snippet.slice(0, SNIPPET_MAX),
        toBlob(e.embedding),
        e.embeddingModel,
        e.decidedAt,
      );
    return id;
  }

  listAll(): StoredExample[] {
    return (this.db.prepare("SELECT * FROM learning_examples").all() as Raw[]).map(toStored);
  }

  listBySet(setId: string): StoredExample[] {
    return (
      this.db.prepare("SELECT * FROM learning_examples WHERE set_id = ?").all(setId) as Raw[]
    ).map(toStored);
  }

  listByModelMismatch(model: string): StoredExample[] {
    return (
      this.db
        .prepare("SELECT * FROM learning_examples WHERE embedding_model <> ?")
        .all(model) as Raw[]
    ).map(toStored);
  }

  /** Newest first; `cursor` is the last id of the previous page (ULIDs sort by time). */
  listPaged(
    userId: string,
    opts: { categoryId?: string; limit: number; cursor?: string },
  ): { items: StoredExample[]; nextCursor: string | null } {
    const where = ["user_id = ?"];
    const args: unknown[] = [userId];
    if (opts.categoryId) {
      where.push("category_id = ?");
      args.push(opts.categoryId);
    }
    if (opts.cursor) {
      where.push("id < ?");
      args.push(opts.cursor);
    }
    const rows = this.db
      .prepare(
        `SELECT * FROM learning_examples WHERE ${where.join(" AND ")} ORDER BY id DESC LIMIT ?`,
      )
      .all(...args, opts.limit + 1) as Raw[];
    const items = rows.slice(0, opts.limit).map(toStored);
    return { items, nextCursor: rows.length > opts.limit ? items.at(-1)!.id : null };
  }

  getOwned(userId: string, id: string): StoredExample | undefined {
    const r = this.db
      .prepare("SELECT * FROM learning_examples WHERE id = ? AND user_id = ?")
      .get(id, userId) as Raw | undefined;
    return r ? toStored(r) : undefined;
  }

  deleteById(id: string): number {
    return this.db.prepare("DELETE FROM learning_examples WHERE id = ?").run(id).changes;
  }

  deleteByCategory(categoryId: string): number {
    return this.db.prepare("DELETE FROM learning_examples WHERE category_id = ?").run(categoryId)
      .changes;
  }

  deleteAllForUser(userId: string): number {
    return this.db.prepare("DELETE FROM learning_examples WHERE user_id = ?").run(userId).changes;
  }

  updateEmbedding(id: string, embedding: Float32Array, model: string): void {
    this.db
      .prepare("UPDATE learning_examples SET embedding = ?, embedding_model = ? WHERE id = ?")
      .run(toBlob(embedding), model, id);
  }
}
