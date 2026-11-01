// Accuracy history: metadata only, never content or category names (data-model.md).
import type { Db } from "../db.js";
import type { Confidence } from "../../suggest/types.js";
import { newId } from "../util.js";
import type { Outcome } from "./learning-examples.js";

export interface DecisionRow {
  outcome: Outcome;
  confidence: Confidence;
  wasNewProposal: boolean;
  decidedAt: string;
}

export class DecisionRepo {
  constructor(private readonly db: Db) {}

  insert(d: DecisionRow & { userId: string; learningExampleId: string | null }): string {
    const id = newId();
    this.db
      .prepare(
        "INSERT INTO decisions (id, user_id, learning_example_id, outcome, confidence, was_new_proposal, decided_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        id,
        d.userId,
        d.learningExampleId,
        d.outcome,
        d.confidence,
        d.wasNewProposal ? 1 : 0,
        d.decidedAt,
      );
    return id;
  }

  deleteAllForUser(userId: string): number {
    return this.db.prepare("DELETE FROM decisions WHERE user_id = ?").run(userId).changes;
  }

  /** The user's latest `n` decisions, newest first. */
  lastN(userId: string, n: number): DecisionRow[] {
    const rows = this.db
      .prepare(
        "SELECT outcome, confidence, was_new_proposal, decided_at FROM decisions WHERE user_id = ? ORDER BY decided_at DESC, id DESC LIMIT ?",
      )
      .all(userId, n) as {
      outcome: Outcome;
      confidence: Confidence;
      was_new_proposal: number;
      decided_at: string;
    }[];
    return rows.map((r) => ({
      outcome: r.outcome,
      confidence: r.confidence,
      wasNewProposal: r.was_new_proposal === 1,
      decidedAt: r.decided_at,
    }));
  }
}
