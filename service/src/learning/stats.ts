// Accuracy over the latest decisions (FR-020). Confirmed and accepted proposals count as
// accepted without correction; corrections do not.
import type { DecisionRepo, DecisionRow } from "../store/repos/decisions.js";

export interface AccuracyStats {
  window: number;
  decisions: number;
  acceptedWithoutCorrection: number | null;
  byConfidence: { high: number | null; medium: number | null; low: number | null };
  newProposals: { made: number; accepted: number };
}

const accepted = (d: DecisionRow) => d.outcome !== "corrected";

function rate(rows: DecisionRow[]): number | null {
  return rows.length ? rows.filter(accepted).length / rows.length : null;
}

export function accuracy(decisions: DecisionRepo, userId: string, window: number): AccuracyStats {
  const rows = decisions.lastN(userId, window);
  const proposals = rows.filter((r) => r.wasNewProposal);
  return {
    window,
    decisions: rows.length,
    acceptedWithoutCorrection: rate(rows),
    byConfidence: {
      high: rate(rows.filter((r) => r.confidence === "high")),
      medium: rate(rows.filter((r) => r.confidence === "medium")),
      low: rate(rows.filter((r) => r.confidence === "low")),
    },
    newProposals: {
      made: proposals.length,
      accepted: proposals.filter((r) => r.outcome === "accepted_new").length,
    },
  };
}
