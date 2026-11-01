export interface Email {
  from: string;
  to?: string[];
  subject: string;
  body: string;
}

export type Confidence = "high" | "medium" | "low";

export interface RankedCategory {
  path: string;
  score: number;
}

/** API response type (contracts/http-api.md). */
export interface Suggestion {
  suggestionId: string;
  category: string;
  isNew: boolean;
  newCategory?: { parent: string | null; name: string };
  confidence: Confidence;
  reason: string;
  runnersUp: RankedCategory[];
  similarPastDecisions: number;
  truncated: boolean;
  expiresAt: string;
}
