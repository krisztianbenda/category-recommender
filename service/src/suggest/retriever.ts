import type { Candidate } from "../categories/path.js";
import type { FewShot } from "./prompt.js";

export interface RetrievalInput {
  userId: string;
  setId: string;
  embedding: Float32Array;
  candidates: Candidate[];
}

export interface Retrieval {
  /** Recency-weighted vote per candidate key, from neighbours the owner filed. */
  votes: Map<string, number>;
  /** Few-shot examples for the prompt, most similar first. Never a deleted email. */
  examples: FewShot[];
  /** Number of learning examples that contributed, deleted ones included. */
  count: number;
  /** Neighbours the owner deleted instead of filing: their weighted vote and how many. */
  deleted: { vote: number; count: number };
  /** Weighted vote of all neighbours the owner filed, whatever the category. */
  filedVote: number;
}

/** Source of the owner's past decisions. US1 ships without learning: NullRetriever. */
export interface Retriever {
  retrieve(input: RetrievalInput): Retrieval;
}

export class NullRetriever implements Retriever {
  retrieve(): Retrieval {
    return {
      votes: new Map(),
      examples: [],
      count: 0,
      deleted: { vote: 0, count: 0 },
      filedVote: 0,
    };
  }
}
