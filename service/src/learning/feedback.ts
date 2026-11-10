// Feedback → learning example + decision (data-model.md state transitions, research R7).
import {
  normaliseName,
  PathError,
  pathKey,
  validateName,
  type Candidate,
} from "../categories/path.js";
import type { Embedder } from "../llm/client.js";
import type { Logger } from "../logging/logger.js";
import { contentHash, type PendingCache, type PendingSuggestion } from "../pending/cache.js";
import type { Db } from "../store/db.js";
import type { CategoryRepo } from "../store/repos/categories.js";
import type { DecisionOutcome, DecisionRepo } from "../store/repos/decisions.js";
import {
  SNIPPET_MAX,
  type LearningExampleRepo,
  type Outcome,
} from "../store/repos/learning-examples.js";
import { nowIso } from "../store/util.js";
import type { Email } from "../suggest/types.js";
import { looseKey } from "../suggest/validate.js";
import { AppError, conflict, invalid } from "../api/errors.js";
import { toEntry, type ExampleIndex } from "./index.js";

export type FeedbackInput =
  | { email: Email; decision: "confirm" }
  | { email: Email; decision: "choose"; category: string }
  | { email: Email; decision: "accept_new"; newCategory: { parent: string | null; name: string } }
  | { email: Email; decision: "delete" };

export interface FeedbackResult {
  learningExampleId: string;
  /** null when the owner deleted the email. */
  categoryId: string | null;
}

export interface FeedbackDeps {
  db: Db;
  categories: CategoryRepo;
  examples: LearningExampleRepo;
  decisions: DecisionRepo;
  index: ExampleIndex;
  pending: PendingCache;
  embedder: Embedder;
  logger: Logger;
}

type Resolved =
  | { path: string; outcome: Exclude<Outcome, "deleted">; isNewCategory: boolean }
  | { path: null; outcome: "deleted"; isNewCategory: false };

const DELETED: Resolved = { path: null, outcome: "deleted", isNewCategory: false };

/**
 * Accuracy history counts a decision as confirmed when the owner did what was suggested: filed
 * where it said, or deleted when it said to delete.
 */
function decisionOutcome(resolved: Resolved, suggestedDelete: boolean): DecisionOutcome {
  if (resolved.outcome === "deleted") return suggestedDelete ? "confirmed" : "corrected";
  return suggestedDelete ? "corrected" : resolved.outcome;
}

function byKey(candidates: Candidate[], path: string): Candidate | undefined {
  const k = pathKey(path);
  return candidates.find((c) => c.key === k);
}

/** Validates an owner-accepted new category: depth ≤ 2, known top-level parent, no duplicate. */
function resolveNew(p: PendingSuggestion, nc: { parent: string | null; name: string }): string {
  let name: string;
  try {
    name = validateName(nc.name);
  } catch (e) {
    if (e instanceof PathError) throw invalid(e.message);
    throw e;
  }
  let parent: Candidate | undefined;
  if (nc.parent !== null) {
    parent = p.candidates.find((c) => c.parentKey === null && c.key === normaliseName(nc.parent!));
    if (!parent) throw invalid("the parent must be an existing top-level category");
  }
  const parentKey = parent?.key ?? null;
  const loose = looseKey(name);
  const dup = p.candidates.find(
    (c) => (c.parentKey === parentKey || c.parentKey === null) && looseKey(c.name) === loose,
  );
  if (dup) throw invalid("that category already exists; choose it instead");
  return parent ? `${parent.path}/${name}` : name;
}

export class FeedbackService {
  constructor(private readonly d: FeedbackDeps) {}

  private resolve(p: PendingSuggestion, input: FeedbackInput): Resolved {
    const suggested = p.result;
    const suggestedDelete = suggested.action === "delete";
    switch (input.decision) {
      case "delete":
        return DELETED;
      case "confirm":
        if (suggestedDelete) return DELETED;
        if (suggested.isNew && suggested.newCategory) {
          return {
            path: resolveNew(p, suggested.newCategory),
            outcome: "accepted_new",
            isNewCategory: true,
          };
        }
        return { path: suggested.category, outcome: "confirmed", isNewCategory: false };
      case "choose": {
        const c = byKey(p.candidates, input.category);
        if (!c) throw invalid("the chosen category was not one of the candidates");
        const same = !suggestedDelete && !suggested.isNew && pathKey(suggested.category) === c.key;
        return { path: c.path, outcome: same ? "confirmed" : "corrected", isNewCategory: false };
      }
      case "accept_new":
        return {
          path: resolveNew(p, input.newCategory),
          outcome: "accepted_new",
          isNewCategory: true,
        };
    }
  }

  async record(
    userId: string,
    suggestionId: string,
    input: FeedbackInput,
  ): Promise<FeedbackResult> {
    const { d } = this;
    const lookup = d.pending.lookup(suggestionId, userId);
    if (lookup.status === "consumed")
      throw conflict("feedback was already given for this suggestion");
    if (lookup.status === "expired") {
      throw new AppError(
        "suggestion_expired",
        410,
        "this suggestion expired, please request a new one",
      );
    }
    const p = lookup.pending;
    if (contentHash(input.email) !== p.contentHash) {
      throw new AppError(
        "content_mismatch",
        409,
        "the email differs from the one that was suggested for",
      );
    }
    if (!d.categories.getSet(userId, p.setId)) throw conflict("the category set no longer exists");
    const resolved = this.resolve(p, input);

    // Saved sets must already contain a chosen category; ad-hoc lists and accepted proposals are
    // upserted (ad-hoc into the default set, research/data-model). A deleted email has none.
    if (
      resolved.path !== null &&
      !p.adHoc &&
      !resolved.isNewCategory &&
      !d.categories.findByPath(p.setId, resolved.path)
    ) {
      throw conflict("that category no longer exists in the set");
    }

    const decidedAt = nowIso();
    const suggestedDelete = p.result.action === "delete";
    const { exampleId, categoryId, created } = d.db.transaction(() => {
      const { id: categoryId, created } =
        resolved.path === null
          ? { id: null, created: [] as string[] }
          : d.categories.upsertPath(p.setId, resolved.path);
      const exampleId = d.examples.insert({
        userId,
        setId: p.setId,
        categoryId,
        suggestedCategoryPath: p.result.category,
        outcome: resolved.outcome,
        sender: input.email.from,
        subject: input.email.subject,
        snippet: input.email.body.trim().slice(0, SNIPPET_MAX),
        embedding: p.embedding,
        embeddingModel: d.embedder.model,
        decidedAt,
      });
      d.decisions.insert({
        userId,
        learningExampleId: exampleId,
        outcome: decisionOutcome(resolved, suggestedDelete),
        confidence: p.confidence,
        wasNewProposal: p.result.isNew && !suggestedDelete,
        wasDeleteSuggestion: suggestedDelete,
        decidedAt,
      });
      return { exampleId, categoryId, created };
    })();

    d.pending.consume(suggestionId);
    d.index.add(
      toEntry({
        id: exampleId,
        userId,
        setId: p.setId,
        categoryId,
        outcome: resolved.outcome,
        sender: input.email.from,
        subject: input.email.subject,
        snippet: input.email.body.trim().slice(0, SNIPPET_MAX),
        embedding: p.embedding,
        embeddingModel: d.embedder.model,
        decidedAt,
      }),
    );

    // Name embeddings for new categories feed the near-duplicate check; best effort.
    if (created.length) {
      const views = d.categories.listCategories(p.setId).filter((c) => created.includes(c.id));
      try {
        const vectors = await d.embedder.embed(views.map((v) => v.name));
        views.forEach((v, i) => d.categories.setNameEmbedding(v.id, vectors[i]!));
      } catch {
        d.logger.warn(
          { errorCode: "name_embedding_failed", count: views.length },
          "category name not embedded",
        );
      }
    }

    d.logger.info(
      { suggestionId, learningExampleId: exampleId, categoryId, setId: p.setId },
      "feedback",
    );
    return { learningExampleId: exampleId, categoryId };
  }
}
