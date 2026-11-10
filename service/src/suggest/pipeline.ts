// Suggestion pipeline: candidates → truncate → embed → retrieve → prompt → LLM → validate →
// confidence → rank → pending cache. Nothing here writes to disk.
import { dedupeCandidates, type Candidate } from "../categories/path.js";
import type { Config } from "../config/schema.js";
import type { Embedder, LlmClient } from "../llm/client.js";
import type { SerialQueue } from "../llm/queue.js";
import { llmResponseSchema } from "../llm/schema.js";
import type { Logger } from "../logging/logger.js";
import { PendingCache } from "../pending/cache.js";
import { contentHash } from "../pending/cache.js";
import type { CategoryRepo, CategoryView } from "../store/repos/categories.js";
import { newId } from "../store/util.js";
import { invalid, notFound } from "../api/errors.js";
import { computeConfidence, knnTop, type KnnSummary } from "./confidence.js";
import {
  comparableTrash,
  decideDeletion,
  deletionShare,
  trashMatches,
  type DeletionEvidence,
} from "./deletion.js";
import { buildMessages } from "./prompt.js";
import type { Retrieval, Retriever } from "./retriever.js";
import { truncateEmail } from "./truncate.js";
import type { Confidence, Email, RankedCategory, Suggestion, TrashedEmail } from "./types.js";
import { validateOutput, type ValidatedChoice } from "./validate.js";

export interface SuggestInput {
  email: Email;
  categories?: string[];
  categorySetId?: string;
  /** The client can act on a suggestion to delete the email. */
  allowDelete?: boolean;
  /** Emails in the owner's Trash that the client found for this one. Used, never stored. */
  trash?: TrashedEmail[];
}

/** A filing suggestion is at most this sure when deleting is about as likely. */
function capped(confidence: Confidence): Confidence {
  return confidence === "high" ? "medium" : confidence;
}

export interface PipelineDeps {
  config: Config;
  categories: CategoryRepo;
  llm: LlmClient;
  embedder: Embedder;
  queue: SerialQueue;
  pending: PendingCache;
  logger: Logger;
  retriever: Retriever;
}

export function toCandidates(views: CategoryView[]): Candidate[] {
  const byId = new Map(views.map((v) => [v.id, v]));
  const tops = views.filter((v) => v.parentId === null);
  const out: Candidate[] = [];
  for (const t of tops) {
    out.push({ path: t.path, key: t.key, name: t.name, parentKey: null });
    for (const c of views.filter((v) => v.parentId === t.id)) {
      out.push({ path: c.path, key: c.key, name: c.name, parentKey: byId.get(t.id)!.key });
    }
  }
  return out;
}

/** Text used for the email's embedding (also used to re-embed stored examples). */
export function embeddingText(e: { from: string; subject: string; body: string }): string {
  return `${e.from}\n${e.subject}\n${e.body.slice(0, 2000)}`;
}

function rankRunnersUp(
  choice: ValidatedChoice,
  candidates: Candidate[],
  retrieval: Retrieval,
): RankedCategory[] {
  const scores = new Map<string, number>();
  // Model ranking: position-based score in (0, 1).
  choice.ranking.forEach((c, i) => scores.set(c.key, (5 - i) / 6));
  // kNN share blended in when the owner has history.
  const total = [...retrieval.votes.values()].reduce((a, b) => a + b, 0);
  if (total > 0) {
    for (const c of candidates) {
      const share = (retrieval.votes.get(c.key) ?? 0) / total;
      if (share === 0 && !scores.has(c.key)) continue;
      scores.set(c.key, 0.5 * (scores.get(c.key) ?? 0) + 0.5 * share);
    }
  }
  const byKey = new Map(candidates.map((c) => [c.key, c]));
  return [...scores.entries()]
    .filter(([key]) => key !== choice.key && byKey.has(key))
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([key, score]) => ({
      path: byKey.get(key)!.path,
      score: Math.round(score * 1000) / 1000,
    }));
}

export class SuggestionPipeline {
  constructor(private readonly d: PipelineDeps) {}

  setRetriever(r: Retriever): void {
    this.d.retriever = r;
  }

  private resolveCandidates(userId: string, input: SuggestInput) {
    if (input.categorySetId !== undefined) {
      const set = this.d.categories.getSet(userId, input.categorySetId);
      if (!set) throw notFound("category set not found");
      const views = this.d.categories.listCategories(set.id);
      return { setId: set.id, adHoc: false, candidates: toCandidates(views), views };
    }
    const set = this.d.categories.getOrCreateDefaultSet(userId);
    return {
      setId: set.id,
      adHoc: true,
      candidates: dedupeCandidates(input.categories ?? []),
      views: [],
    };
  }

  /**
   * When enough similar past decisions agree strongly, they win over the model's answer
   * (research R6 addendum): the owner's habits beat a generic model.
   */
  private applyOverride(
    choice: ValidatedChoice,
    candidates: Candidate[],
    knn: KnnSummary | null,
  ): ValidatedChoice | null {
    const { share, minExamples } = this.d.config.learning.override;
    if (!knn || knn.count < minExamples) return null;
    const top = knnTop(knn);
    if (!top || top.share < share || top.key === choice.key) return null;
    const target = candidates.find((c) => c.key === top.key);
    if (!target) return null;
    const previous = choice.isNew ? [] : candidates.filter((c) => c.key === choice.key);
    return {
      ...choice,
      category: target.path,
      key: target.key,
      isNew: false,
      newCategory: null,
      reason: `Your past decisions for similar emails point to ${target.path}.`,
      ranking: [...previous, ...choice.ranking.filter((c) => c.key !== target.key)].slice(0, 5),
      forcedLow: false,
    };
  }

  async suggest(userId: string, input: SuggestInput): Promise<Suggestion> {
    const { config, embedder, llm, queue, pending, retriever } = this.d;
    if (!input.email.subject.trim() && !input.email.body.trim()) {
      throw invalid("the email needs a subject or a body");
    }
    const { setId, adHoc, candidates, views } = this.resolveCandidates(userId, input);
    const { email, truncated } = truncateEmail(input.email, config.llm.maxEmailTokens);

    // Trashed emails are compared by subject in the same embedding request as the email itself.
    const deletion = config.learning.deletion;
    const canDelete = input.allowDelete === true && deletion.enabled;
    const trash = canDelete ? comparableTrash(email, input.trash ?? []) : [];
    const subjects = trash.length ? [email.subject, ...trash.map((t) => t.subject)] : [];
    const [embedding, subjectVector, ...trashVectors] = await embedder.embed([
      embeddingText(email),
      ...subjects,
    ]);
    const retrieval = retriever.retrieve({ userId, setId, embedding: embedding!, candidates });

    const { messages } = buildMessages({
      candidates,
      email,
      examples: retrieval.examples,
      model: llm.model,
    });
    const raw = await queue.run(() => llm.chat(messages, llmResponseSchema));

    const stored = new Map(
      views.filter((v) => v.nameEmbedding).map((v) => [v.name, v.nameEmbedding!]),
    );
    let choice = await validateOutput(raw, candidates, {
      duplicateSimilarity: config.learning.newCategoryDuplicateSimilarity,
      nameEmbeddings: async (names) => {
        const missing = names.filter((n) => !stored.has(n));
        const computed = await embedder.embed(missing);
        const fresh = new Map(missing.map((n, i) => [n, computed[i]!]));
        return names.map((n) => stored.get(n) ?? fresh.get(n)!);
      },
    });

    const knn: KnnSummary | null =
      retrieval.count > 0 ? { votes: retrieval.votes, count: retrieval.count } : null;
    const noFit = choice.isNew || choice.forcedLow || choice.llmConfidence === "low";
    const overridden = this.applyOverride(choice, candidates, knn);
    if (overridden) choice = overridden;
    let confidence = overridden
      ? "medium"
      : computeConfidence({
          llmConfidence: choice.llmConfidence,
          chosenKey: choice.key,
          isNew: choice.isNew,
          forcedLow: choice.forcedLow,
          knn,
          agreeShare: config.learning.confidence.knnAgreeShare,
        });

    // Deleting rather than filing: the owner's past deletions and their Trash are the evidence.
    const evidence: DeletionEvidence = {
      deleted: canDelete ? retrieval.deleted : { vote: 0, count: 0 },
      trash: trashMatches(
        subjectVector,
        trashVectors,
        deletion.trashSimilarity,
        config.learning.neighbours,
      ),
      filedVote: retrieval.filedVote,
    };
    const verdict = canDelete
      ? decideDeletion(evidence, noFit && !overridden, {
          override: config.learning.override,
          noFitShare: deletion.noFitShare,
        })
      : null;
    if (verdict) confidence = verdict.confidence;
    else if (deletionShare(evidence) >= deletion.noFitShare) confidence = capped(confidence);

    const now = Date.now();
    const expiresAt = now + pending.ttlMs;
    const suggestion: Suggestion = {
      suggestionId: newId(),
      action: verdict ? "delete" : "file",
      category: choice.category,
      isNew: choice.isNew,
      ...(choice.isNew && choice.newCategory ? { newCategory: choice.newCategory } : {}),
      confidence,
      reason: verdict?.reason ?? choice.reason,
      runnersUp: rankRunnersUp(choice, candidates, retrieval),
      similarPastDecisions: retrieval.count,
      similarDeleted: retrieval.deleted.count,
      similarInTrash: evidence.trash.count,
      truncated,
      expiresAt: new Date(expiresAt).toISOString(),
    };
    pending.put({
      id: suggestion.suggestionId,
      userId,
      setId,
      adHoc,
      candidates,
      contentHash: contentHash(input.email),
      embedding: embedding!,
      result: suggestion,
      confidence,
      createdAt: now,
      expiresAt,
    });
    this.d.logger.info(
      {
        suggestionId: suggestion.suggestionId,
        setId,
        model: llm.model,
        confidence,
        action: suggestion.action,
        isNew: suggestion.isNew,
        count: retrieval.count,
        deletedCount: retrieval.deleted.count,
        trashCount: input.trash?.length ?? 0,
        trashMatched: evidence.trash.count,
      },
      "suggestion",
    );
    return suggestion;
  }
}
