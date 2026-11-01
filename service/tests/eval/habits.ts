// Habits suite (SC-002, SC-003): replays a scripted owner who gives feedback after every
// suggestion. Requires the learning loop (US2); without it, acceptance cannot improve.
import type { AppContext } from "../../src/context.js";
import type { Email } from "../../src/suggest/types.js";
import { pathKey } from "../../src/categories/path.js";

export interface HabitsResult {
  first100: number;
  last100: number;
  acceptedAfter200: number;
  habitFirst100: number;
  habitLast100: number;
}

interface HabitItem {
  email: Email;
  truth: string;
  habit: boolean;
}

export async function runHabits(
  ctx: AppContext,
  script: { categories: string[]; items: HabitItem[] },
  opts: { onSuggest: (ms: number) => void; sample: () => void; limit: number },
): Promise<HabitsResult> {
  const feedback = ctx.feedback;
  if (!feedback) throw new Error("the habits suite needs the learning loop (US2)");
  const outcomes: { accepted: boolean; habit: boolean }[] = [];
  for (const it of script.items.slice(0, opts.limit)) {
    const t0 = performance.now();
    const s = await ctx.pipeline.suggest("owner", {
      email: it.email,
      categories: script.categories,
    });
    opts.onSuggest(performance.now() - t0);
    const accepted = !s.isNew && pathKey(s.category) === pathKey(it.truth);
    await feedback.record("owner", s.suggestionId, {
      email: it.email,
      ...(accepted
        ? { decision: "confirm" as const }
        : { decision: "choose" as const, category: it.truth }),
    });
    outcomes.push({ accepted, habit: it.habit });
    opts.sample();
  }
  const rate = (xs: { accepted: boolean }[]) =>
    xs.length ? xs.filter((x) => x.accepted).length / xs.length : NaN;
  const first = outcomes.slice(0, 100);
  const last = outcomes.slice(-100);
  return {
    first100: rate(first),
    last100: rate(last),
    acceptedAfter200: rate(outcomes.slice(200)),
    habitFirst100: rate(first.filter((o) => o.habit)),
    habitLast100: rate(last.filter((o) => o.habit)),
  };
}
