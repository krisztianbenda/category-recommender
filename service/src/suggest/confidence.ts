// Confidence is computed in code, not taken from the model alone (research R6).
import type { LlmConfidence } from "../llm/schema.js";
import type { Confidence } from "./types.js";

export interface KnnSummary {
  /** Vote per category key. */
  votes: Map<string, number>;
  /** Number of learning examples that contributed. */
  count: number;
}

export interface ConfidenceInput {
  llmConfidence: LlmConfidence;
  chosenKey: string;
  isNew: boolean;
  forcedLow: boolean;
  knn: KnnSummary | null;
  /** learning.confidence.knnAgreeShare (default 0.6). */
  agreeShare: number;
}

export function knnTop(knn: KnnSummary): { key: string; share: number } | null {
  let total = 0;
  let top: { key: string; vote: number } | null = null;
  for (const [key, vote] of knn.votes) {
    total += vote;
    if (!top || vote > top.vote) top = { key, vote };
  }
  return top && total > 0 ? { key: top.key, share: top.vote / total } : null;
}

export function computeConfidence(i: ConfidenceInput): Confidence {
  if (i.isNew || i.forcedLow || i.llmConfidence === "low") return "low";
  const top = i.knn && i.knn.count > 0 ? knnTop(i.knn) : null;
  if (!top) return i.llmConfidence === "high" ? "high" : "medium";
  if (top.share >= i.agreeShare) return top.key === i.chosenKey ? "high" : "low";
  return "medium";
}
