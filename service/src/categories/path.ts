// Category paths: "Name" or "Parent/Child", at most two levels (FR-002).

export const MAX_NAME_LENGTH = 60;

export class PathError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PathError";
  }
}

/** Lower-case, accents folded, whitespace collapsed, trimmed. */
export function normaliseName(name: string): string {
  return name.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().replace(/\s+/g, " ").trim();
}

export interface ParsedPath {
  parent: string | null;
  name: string;
}

/** Validates and splits a path. Throws PathError on depth > 2, empty or over-long segments. */
export function parsePath(path: string): ParsedPath {
  const segments = path.split("/").map((s) => s.replace(/\s+/g, " ").trim());
  if (segments.length > 2) throw new PathError("categories are at most two levels deep");
  for (const s of segments) {
    if (s.length === 0) throw new PathError("category names must not be empty");
    if (s.length > MAX_NAME_LENGTH) {
      throw new PathError(`category names must be at most ${MAX_NAME_LENGTH} characters`);
    }
  }
  return segments.length === 2
    ? { parent: segments[0]!, name: segments[1]! }
    : { parent: null, name: segments[0]! };
}

/** Validates a single category name (no '/'). */
export function validateName(name: string): string {
  if (name.includes("/")) throw new PathError("category names must not contain '/'");
  return parsePath(name).name;
}

export function formatPath(p: ParsedPath): string {
  return p.parent === null ? p.name : `${p.parent}/${p.name}`;
}

export function pathKey(path: string): string {
  return path.split("/").map(normaliseName).join("/");
}

export interface Candidate {
  /** Display path, first-seen casing. */
  path: string;
  key: string;
  name: string;
  parentKey: string | null;
}

/**
 * De-duplicates case-insensitively and adds implied parents (`A/B` without `A` implies `A`).
 * Order: first-seen, with an implied parent inserted before its first child.
 */
export function dedupeCandidates(paths: string[]): Candidate[] {
  const out: Candidate[] = [];
  const seen = new Set<string>();
  const add = (c: Candidate) => {
    if (seen.has(c.key)) return;
    seen.add(c.key);
    out.push(c);
  };
  for (const raw of paths) {
    const p = parsePath(raw);
    if (p.parent !== null) {
      const parentKey = normaliseName(p.parent);
      add({ path: p.parent, key: parentKey, name: p.parent, parentKey: null });
      const path = formatPath(p);
      add({ path, key: pathKey(path), name: p.name, parentKey });
    } else {
      add({ path: p.name, key: normaliseName(p.name), name: p.name, parentKey: null });
    }
  }
  // Use the parent's display casing for children too.
  const display = new Map(out.filter((c) => c.parentKey === null).map((c) => [c.key, c.name]));
  return out.map((c) =>
    c.parentKey === null
      ? c
      : { ...c, path: `${display.get(c.parentKey) ?? c.parentKey}/${c.name}` },
  );
}

/** Indented tree for prompts: top-level entries, each followed by its subcategories. */
export function renderTree(candidates: Candidate[]): string {
  const lines: string[] = [];
  for (const top of candidates.filter((c) => c.parentKey === null)) {
    lines.push(`- ${top.path}`);
    for (const child of candidates.filter((c) => c.parentKey === top.key)) {
      lines.push(`  - ${child.path}`);
    }
  }
  return lines.join("\n");
}
