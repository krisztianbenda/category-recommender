// Contract: POST /v1/suggestions/{id}/feedback (contracts/http-api.md) and the learning effect.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { startTestApp, type TestApp } from "../helpers/app.js";
import { keywordChat } from "../helpers/keyword-chat.js";

let t: TestApp;

beforeAll(async () => {
  t = await startTestApp();
});
afterAll(async () => t.close());
beforeEach(() => {
  t.stub.setChat(keywordChat);
});

const CATS = ["Family", "Family/Baby", "Gadgets", "Finance", "Travelling"];
const dad = {
  from: "Dad <dad@example.test>",
  subject: "Sunday lunch",
  body: "The whole family meets at grandma's on Sunday.",
};
const booking = {
  from: "Booking <b@travel.example.test>",
  subject: "Hotel booking",
  body: "Your hotel reservation in Lisbon is confirmed.",
};

async function suggest(email: unknown, categories = CATS) {
  const res = await t.call<any>("POST", "/v1/suggestions", { email, categories });
  expect(res.status).toBe(200);
  return res.body;
}
const feedback = (id: string, body: unknown) =>
  t.call<any>("POST", `/v1/suggestions/${id}/feedback`, body);

describe("POST /v1/suggestions/{id}/feedback", () => {
  it("201 on confirm, returning ids", async () => {
    const s = await suggest(dad);
    const res = await feedback(s.suggestionId, { email: dad, decision: "confirm" });
    expect(res.status).toBe(201);
    expect(res.body.learningExampleId).toMatch(/^[0-9A-Z]{26}$/);
    expect(res.body.categoryId).toMatch(/^[0-9A-Z]{26}$/);
  });

  it("201 on choose of another candidate; 400 for a non-candidate", async () => {
    const s = await suggest(dad);
    expect(
      (await feedback(s.suggestionId, { email: dad, decision: "choose", category: "Elsewhere" }))
        .status,
    ).toBe(400);
    const ok = await feedback(s.suggestionId, {
      email: dad,
      decision: "choose",
      category: "family/baby",
    });
    expect(ok.status).toBe(201);
  });

  it("requires category for choose and newCategory for accept_new", async () => {
    const s = await suggest(dad);
    expect((await feedback(s.suggestionId, { email: dad, decision: "choose" })).status).toBe(400);
    expect((await feedback(s.suggestionId, { email: dad, decision: "accept_new" })).status).toBe(
      400,
    );
    expect((await feedback(s.suggestionId, { email: dad, decision: "maybe" })).status).toBe(400);
  });

  it("accept_new creates the category (edited name allowed) in the default set", async () => {
    const s = await suggest(booking);
    expect(s.isNew).toBe(true);
    const res = await feedback(s.suggestionId, {
      email: booking,
      decision: "accept_new",
      newCategory: { parent: "Travelling", name: "Trip Lisbon 2027" },
    });
    expect(res.status).toBe(201);
    const set = t.app.ctx.categories.getOrCreateDefaultSet("owner");
    expect(t.app.ctx.categories.findByPath(set.id, "Travelling/Trip Lisbon 2027")?.id).toBe(
      res.body.categoryId,
    );
  });

  it("confirm of a proposal is the same as accept_new with the proposed name", async () => {
    const s = await suggest(booking, ["Travelling", "Family"]);
    expect(s.isNew).toBe(true);
    const res = await feedback(s.suggestionId, { email: booking, decision: "confirm" });
    expect(res.status).toBe(201);
    const set = t.app.ctx.categories.getOrCreateDefaultSet("owner");
    expect(t.app.ctx.categories.findByPath(set.id, s.category)?.id).toBe(res.body.categoryId);
  });

  it("accept_new rejects depth > 2, an unknown parent and near-duplicates", async () => {
    const s = await suggest(booking);
    const bad = [
      { parent: "Travelling", name: "A/B" },
      { parent: "Family/Baby", name: "Clothes" },
      { parent: "Holidays", name: "Lisbon" },
      { parent: null, name: "Gadget" },
      { parent: null, name: "family" },
    ];
    for (const newCategory of bad) {
      const res = await feedback(s.suggestionId, {
        email: booking,
        decision: "accept_new",
        newCategory,
      });
      expect(res.status, JSON.stringify(newCategory)).toBe(400);
    }
  });

  it("409 content_mismatch when the email changed", async () => {
    const s = await suggest(dad);
    const res = await feedback(s.suggestionId, {
      email: { ...dad, body: "something else" },
      decision: "confirm",
    });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("content_mismatch");
  });

  it("409 on a second feedback", async () => {
    const s = await suggest(dad);
    expect((await feedback(s.suggestionId, { email: dad, decision: "confirm" })).status).toBe(201);
    const again = await feedback(s.suggestionId, { email: dad, decision: "confirm" });
    expect(again.status).toBe(409);
  });

  it("410 suggestion_expired after the TTL", async () => {
    const s = await suggest(dad);
    const l = t.app.ctx.pending.lookup(s.suggestionId, "owner");
    if (l.status !== "ok") throw new Error("expected pending");
    l.pending.expiresAt = Date.now() - 1;
    const res = await feedback(s.suggestionId, { email: dad, decision: "confirm" });
    expect(res.status).toBe(410);
    expect(res.body.error.code).toBe("suggestion_expired");
  });

  it("410 after a restart (pending suggestions live in memory only)", async () => {
    const s = await suggest(dad);
    await t.restart();
    const res = await feedback(s.suggestionId, { email: dad, decision: "confirm" });
    expect(res.status).toBe(410);
  });

  it("404 for a malformed id is a 400", async () => {
    expect((await feedback("not-an-id", { email: dad, decision: "confirm" })).status).toBe(400);
  });
});

describe("learning effect (US2, quickstart V5)", () => {
  it("after 3 corrections of shop receipts to Finance, the next similar receipt is Finance", async () => {
    const receipt = (n: number) => ({
      from: "GadgetMart <orders@gadgetmart.example.test>",
      subject: `GadgetMart receipt ${n}`,
      body: `Thanks for shopping at GadgetMart. Receipt for your new device, order ${n}, paid by card.`,
    });
    const cats = ["Family", "Gadgets", "Finance"];
    const first = await suggest(receipt(1), cats);
    expect(first.category).toBe("Gadgets"); // the "model" thinks devices are gadgets
    for (let i = 1; i <= 3; i++) {
      const s = i === 1 ? first : await suggest(receipt(i), cats);
      const res = await feedback(s.suggestionId, {
        email: receipt(i),
        decision: "choose",
        category: "Finance",
      });
      expect(res.status).toBe(201);
    }
    const next = await suggest(receipt(4), cats);
    expect(next.category).toBe("Finance");
    expect(next.similarPastDecisions).toBeGreaterThanOrEqual(3);
    // the model's few-shot block now lists the owner's past decisions
    const lastPrompt = t.stub.chatCalls
      .at(-1)!
      .messages.map((m) => m.content)
      .join("\n");
    expect(lastPrompt).toMatch(/GadgetMart receipt \d.*=> Finance/);
  });

  it("an email without feedback does not influence learning", async () => {
    const lonely = {
      from: "Zed <zed@example.test>",
      subject: "Zebra zither zone",
      body: "Zebra zither zone zigzag.",
    };
    await suggest(lonely);
    const again = await suggest(lonely);
    expect(again.similarPastDecisions).toBe(0);
  });
});
