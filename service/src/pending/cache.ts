// In-memory pending suggestions (research R7). Holds a content hash and an embedding, never the
// email text; nothing here is ever written to disk. Lost on restart by design.
import crypto from "node:crypto";
import type { Candidate } from "../categories/path.js";
import type { Confidence, Email, Suggestion } from "../suggest/types.js";

export interface PendingSuggestion {
  id: string;
  userId: string;
  setId: string;
  adHoc: boolean;
  candidates: Candidate[];
  contentHash: string;
  embedding: Float32Array;
  result: Suggestion;
  confidence: Confidence;
  createdAt: number;
  expiresAt: number;
}

export type Lookup =
  { status: "ok"; pending: PendingSuggestion } | { status: "expired" } | { status: "consumed" };

export function contentHash(email: Email): string {
  const normalised = JSON.stringify({
    from: email.from.trim(),
    subject: email.subject.trim(),
    body: email.body.trim(),
  });
  return crypto.createHash("sha256").update(normalised).digest("hex");
}

export class PendingCache {
  private readonly entries = new Map<string, PendingSuggestion>();
  /** Ids that already received feedback, kept until their original expiry (ids only). */
  private readonly consumed = new Map<string, { userId: string; expiresAt: number }>();
  private timer: NodeJS.Timeout | undefined;

  constructor(
    readonly ttlMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  start(sweepMs = 60_000): void {
    this.timer = setInterval(() => this.sweep(), sweepMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  put(p: PendingSuggestion): void {
    this.entries.set(p.id, p);
  }

  lookup(id: string, userId: string): Lookup {
    const c = this.consumed.get(id);
    if (c && c.userId === userId && c.expiresAt > this.now()) return { status: "consumed" };
    const p = this.entries.get(id);
    if (!p || p.userId !== userId) return { status: "expired" };
    if (p.expiresAt <= this.now()) {
      this.entries.delete(id);
      return { status: "expired" };
    }
    return { status: "ok", pending: p };
  }

  /** Removes the entry and remembers that its id was used. */
  consume(id: string): void {
    const p = this.entries.get(id);
    if (!p) return;
    this.entries.delete(id);
    this.consumed.set(id, { userId: p.userId, expiresAt: p.expiresAt });
  }

  purgeUser(userId: string): void {
    for (const [id, p] of this.entries) if (p.userId === userId) this.entries.delete(id);
  }

  sweep(): void {
    const now = this.now();
    for (const [id, p] of this.entries) if (p.expiresAt <= now) this.entries.delete(id);
    for (const [id, c] of this.consumed) if (c.expiresAt <= now) this.consumed.delete(id);
  }

  get size(): number {
    return this.entries.size;
  }
}
