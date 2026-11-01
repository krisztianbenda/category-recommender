import type { Email } from "./types.js";

export const estimateTokens = (s: string): number => Math.ceil(s.length / 4);

/**
 * Keeps sender and subject, cuts the body to fit `maxTokens` (≈ 4 chars per token), preferring a
 * whitespace boundary. Research R9.
 */
export function truncateEmail(
  email: Email,
  maxTokens: number,
): { email: Email; truncated: boolean } {
  const header = `${email.from}\n${(email.to ?? []).join(", ")}\n${email.subject}\n`;
  const budgetChars = Math.max(0, maxTokens * 4 - header.length);
  if (email.body.length <= budgetChars) return { email, truncated: false };
  let cut = email.body.slice(0, budgetChars);
  const lastSpace = cut.search(/\s\S*$/);
  if (lastSpace > budgetChars * 0.8) cut = cut.slice(0, lastSpace);
  return { email: { ...email, body: cut.trimEnd() }, truncated: true };
}
