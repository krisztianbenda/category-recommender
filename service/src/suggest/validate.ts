// Validates model output against the candidates (research R5, R8). The model can never pick a
// category outside the list, go deeper than two levels, or slip in a near-duplicate.
import { normaliseName, PathError, validateName, type Candidate } from "../categories/path.js";
import { cosine, LlmOutputError } from "../llm/client.js";
import { isLlmSuggestion, type LlmConfidence } from "../llm/schema.js";

export interface ValidatedChoice {
  /** Display path of the chosen (or proposed) category. */
  category: string;
  key: string;
  isNew: boolean;
  newCategory: { parent: string | null; name: string } | null;
  llmConfidence: LlmConfidence;
  reason: string;
  /** Other existing candidates from the model's ranking, best first, max 5. */
  ranking: Candidate[];
  /** The model's answer was unusable and a fallback was chosen. */
  forcedLow: boolean;
}

export interface ValidateOptions {
  /** Embeddings for category names (stored ones for saved sets, computed for ad-hoc lists). */
  nameEmbeddings: (names: string[]) => Promise<Float32Array[]>;
  duplicateSimilarity: number;
}

/** Normalised name with a trailing plural "s" removed: "Gadgets" ~ "Gadget". */
export const looseKey = (name: string) => normaliseName(name).replace(/(?<=\w{3})s$/, "");

function byKey(candidates: Candidate[], key: string): Candidate | undefined {
  const k = key
    .split("/")
    .map((s) => normaliseName(s))
    .join("/");
  return candidates.find((c) => c.key === k);
}

function mapRanking(ranking: string[], candidates: Candidate[], exclude: string): Candidate[] {
  const out: Candidate[] = [];
  for (const r of ranking) {
    const c = byKey(candidates, r);
    if (c && c.key !== exclude && !out.includes(c)) out.push(c);
    if (out.length === 5) break;
  }
  return out;
}

async function findDuplicate(
  parentKey: string | null,
  name: string,
  candidates: Candidate[],
  opts: ValidateOptions,
): Promise<Candidate | undefined> {
  // Same path, or same loose name among siblings first, then anywhere.
  const loose = looseKey(name);
  const siblings = candidates.filter((c) => c.parentKey === parentKey);
  const byName =
    siblings.find((c) => looseKey(c.name) === loose) ??
    candidates.find((c) => looseKey(c.name) === loose);
  if (byName) return byName;
  if (siblings.length === 0) return undefined;
  const [proposed, ...existing] = await opts.nameEmbeddings([name, ...siblings.map((c) => c.name)]);
  let best: { c: Candidate; sim: number } | undefined;
  existing.forEach((e, i) => {
    const sim = cosine(proposed!, e);
    if (!best || sim > best.sim) best = { c: siblings[i]!, sim };
  });
  return best && best.sim >= opts.duplicateSimilarity ? best.c : undefined;
}

export async function validateOutput(
  raw: unknown,
  candidates: Candidate[],
  opts: ValidateOptions,
): Promise<ValidatedChoice> {
  if (!isLlmSuggestion(raw)) throw new LlmOutputError("model output did not match the schema");
  const out = raw;
  const reason = out.reason.trim().split(/\s+/).slice(0, 25).join(" ");
  const existing = (c: Candidate, forcedLow = false): ValidatedChoice => ({
    category: c.path,
    key: c.key,
    isNew: false,
    newCategory: null,
    llmConfidence: out.confidence,
    reason,
    ranking: mapRanking(out.ranking, candidates, c.key),
    forcedLow,
  });

  let proposal: { parent: string | null; name: string } | null = null;
  if (out.isNew && out.newCategory) proposal = out.newCategory;
  else if (!out.isNew && out.category) {
    const c = byKey(candidates, out.category);
    if (c) return existing(c);
    if (candidates.length === 0) proposal = { parent: null, name: out.category };
    else {
      // Not a candidate: fall back to the best valid ranking entry, else the first candidate.
      const fallback = mapRanking(out.ranking, candidates, "")[0] ?? candidates[0]!;
      return existing(fallback, true);
    }
  }
  if (!proposal) throw new LlmOutputError("model output had neither a category nor a proposal");

  let name: string;
  try {
    name = validateName(proposal.name);
  } catch (e) {
    if (e instanceof PathError) throw new LlmOutputError("model proposed an invalid category name");
    throw e;
  }
  // Parent must be an existing top-level candidate, otherwise the proposal becomes top-level.
  const parent =
    proposal.parent === null
      ? undefined
      : candidates.find((c) => c.parentKey === null && c.key === normaliseName(proposal.parent!));
  const parentKey = parent?.key ?? null;

  const exact = byKey(candidates, parent ? `${parent.name}/${name}` : name);
  if (exact) return existing(exact);
  const dup = await findDuplicate(parentKey, name, candidates, opts);
  if (dup) return existing(dup);

  const path = parent ? `${parent.path}/${name}` : name;
  return {
    category: path,
    key: parent ? `${parent.key}/${normaliseName(name)}` : normaliseName(name),
    isNew: true,
    newCategory: { parent: parent?.path ?? null, name },
    llmConfidence: out.confidence,
    reason,
    ranking: mapRanking(out.ranking, candidates, ""),
    forcedLow: false,
  };
}
