// A deterministic "model" for contract tests: picks categories by keywords in the email.
import { defaultChat, type ChatHandler } from "./stub-llm.js";

const RULES: [RegExp, string][] = [
  [/\b(baby|paediatrician|newborn)\b/i, "Family/Baby"],
  [/\b(grandma|family|dad|aunt|cousins)\b/i, "Family"],
  [/\b(iphone|device|gadget|laptop)\b/i, "Gadgets"],
  [/\b(invoice|receipt|bank|payment)\b/i, "Finance"],
];

export const keywordChat: ChatHandler = (req, ctx) => {
  const { candidates, email } = ctx;
  const has = (p: string) => candidates.find((c) => c.toLowerCase() === p.toLowerCase());
  if (/\b(booking|reservation|hotel)\b/i.test(email)) {
    const parent = has("Travelling") ?? null;
    return {
      isNew: true,
      newCategory: { parent, name: "Trip Lisbon" },
      confidence: "medium",
      reason: "a new trip that has no category yet",
      ranking: candidates.filter((c) => c.startsWith("Travelling")).slice(0, 5),
    };
  }
  for (const [re, path] of RULES) {
    if (re.test(email) && has(path)) {
      return {
        isNew: false,
        category: has(path),
        confidence: "high",
        reason: `mentions ${path.toLowerCase()} topics`,
        ranking: candidates.filter((c) => c !== has(path)).slice(0, 5),
      };
    }
  }
  if (candidates.length === 0) {
    return {
      isNew: true,
      newCategory: { parent: null, name: "Personal" },
      confidence: "low",
      reason: "no categories were given",
      ranking: [],
    };
  }
  return defaultChat(req, ctx);
};
