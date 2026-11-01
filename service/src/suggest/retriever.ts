import type { Candidate } from "../categories/path.js";
import type { FewShot } from "./prompt.js";

export interface RetrievalInput {
  userId: string;
  setId: string;
  embedding: Float32Array;
  candidates: Candidate[];
}

export interface Retrieval {
  /** Recency-weighted vote per candidate key. */
  votes: Map<string, number>;
  /** Few-shot examples for the prompt, most similar first. */
  examples: FewShot[];
  /** Number of learning examples that contributed. */
  count: number;
}

/** Source of the owner's past decisions. US1 ships without learning: NullRetriever. */
export interface Retriever {
  retrieve(input: RetrievalInput): Retrieval;
}

export class NullRetriever implements Retriever {
  retrieve(): Retrieval {
    return { votes: new Map(), examples: [], count: 0 };
  }
}
