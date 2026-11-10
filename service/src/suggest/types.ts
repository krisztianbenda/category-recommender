export interface Email {
  from: string;
  to?: string[];
  subject: string;
  body: string;
}

export type Confidence = "high" | "medium" | "low";

/** What the suggestion asks the owner to do with the email. */
export type SuggestedAction = "file" | "delete";

/** An email in the owner's Trash, as the client found it: never stored. */
export interface TrashedEmail {
  from: string;
  subject: string;
}

export interface RankedCategory {
  path: string;
  score: number;
}

/** API response type (contracts/http-api.md). */
export interface Suggestion {
  suggestionId: string;
  /** "delete" only when the client allowed it. `category` is then where to file it if kept. */
  action: SuggestedAction;
  category: string;
  isNew: boolean;
  newCategory?: { parent: string | null; name: string };
  confidence: Confidence;
  reason: string;
  runnersUp: RankedCategory[];
  similarPastDecisions: number;
  /** Of those, how many the owner deleted. */
  similarDeleted: number;
  /** Similar emails from the same sender in the Trash, among those the client sent. */
  similarInTrash: number;
  truncated: boolean;
  expiresAt: string;
}
