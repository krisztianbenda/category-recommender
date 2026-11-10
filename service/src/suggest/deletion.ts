// Whether to suggest deleting the email rather than filing it (specs/003-delete-suggestion).
//
// The evidence is the owner's own behaviour: similar emails they deleted through the recommender,
// and similar emails from the same sender that are in the Trash now. The model only says whether
// a label fits; it never decides on deletion, and the decision is made here, in code.
import { cosine } from "../llm/client.js";
import type { Confidence, TrashedEmail } from "./types.js";

export interface Weighed {
  vote: number;
  count: number;
}

export interface DeletionEvidence {
  /** Similar emails the owner deleted, among the nearest past decisions. */
  deleted: Weighed;
  /** Similar emails from the same sender in the Trash. */
  trash: Weighed;
  /** Weighted vote of the similar emails the owner filed. */
  filedVote: number;
}

export interface DeletionRules {
  /** The habit rule, shared with the override of the model by past decisions. */
  override: { share: number; minExamples: number };
  /** The share that is enough when no label fits. */
  noFitShare: number;
}

export interface DeletionVerdict {
  confidence: Confidence;
  reason: string;
}

const NONE: Weighed = { vote: 0, count: 0 };

/** Share of the evidence that points to deletion, 0 when there is none. */
export function deletionShare(e: DeletionEvidence): number {
  const vote = e.deleted.vote + e.trash.vote;
  return vote > 0 ? vote / (vote + e.filedVote) : 0;
}

const emails = (n: number) => (n === 1 ? "1 similar email" : `${n} similar emails`);

export function deletionReason(e: DeletionEvidence, noFit: boolean): string {
  const parts: string[] = [];
  if (e.deleted.count > 0) parts.push(`You deleted ${emails(e.deleted.count)} before`);
  if (e.trash.count > 0) {
    const be = e.trash.count === 1 ? "is" : "are";
    parts.push(
      e.deleted.count > 0
        ? `${e.trash.count} from this sender ${be} in the Trash`
        : `${emails(e.trash.count)} from this sender ${be} in the Trash`,
    );
  }
  return `${noFit ? "No label fits well. " : ""}${parts.join(", and ")}.`;
}

/**
 * Deletion is suggested when the evidence for it is as strong as a habit that overrides the
 * model, or, when the model found no label that fits, when it is at least `noFitShare` of the
 * evidence. Null means: file it.
 */
export function decideDeletion(
  e: DeletionEvidence,
  noFit: boolean,
  rules: DeletionRules,
): DeletionVerdict | null {
  const count = e.deleted.count + e.trash.count;
  if (count === 0) return null;
  const share = deletionShare(e);
  const enough = count >= rules.override.minExamples;
  const habit = enough && share >= rules.override.share;
  const nowhere = noFit && share >= rules.noFitShare;
  if (!habit && !nowhere) return null;
  const confidence: Confidence = habit ? (noFit ? "high" : "medium") : enough ? "medium" : "low";
  return { confidence, reason: deletionReason(e, noFit) };
}

/** The address part of a From header, lower case: "Shop <News@Shop.test>" → "news@shop.test". */
export function senderAddress(from: string): string {
  const inBrackets = /<([^<>]+)>/.exec(from)?.[1];
  const bare = /[^\s<>"]+@[^\s<>"]+/.exec(from)?.[0];
  return (inBrackets ?? bare ?? from).trim().toLowerCase();
}

/** Trashed emails that can be compared with this one: same sender, with a subject. */
export function comparableTrash(
  email: { from: string; subject: string },
  trash: TrashedEmail[],
): TrashedEmail[] {
  if (!email.subject.trim()) return [];
  const sender = senderAddress(email.from);
  return trash.filter((t) => t.subject.trim() && senderAddress(t.from) === sender);
}

/**
 * Trashed emails whose subject is about the same thing as this one's. The sender is already the
 * same, so only the subjects are compared. At most `limit`, the most similar.
 */
export function trashMatches(
  subject: Float32Array | undefined,
  trashed: Float32Array[],
  similarity: number,
  limit: number,
): Weighed {
  if (!subject || trashed.length === 0) return NONE;
  const sims = trashed
    .map((v) => cosine(subject, v))
    .filter((s) => s >= similarity)
    .sort((a, b) => b - a)
    .slice(0, limit);
  return { vote: sims.reduce((a, b) => a + b, 0), count: sims.length };
}
