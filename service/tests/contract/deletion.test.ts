// Contract: suggesting deletion (specs/003-delete-suggestion, contracts/http-api.md).
import { describe, expect, it } from "vitest";
import { useTestApp } from "../helpers/app.js";
import type { ChatHandler } from "../helpers/stub-llm.js";

const t = useTestApp();

const CATS = ["Family", "Gadgets", "Finance", "Shopping"];

/** The "model" finds that the first label fits only poorly. */
const nothingFits: ChatHandler = (_req, { candidates }) => ({
  isNew: false,
  category: candidates[0],
  confidence: "low",
  reason: "nothing really fits",
  ranking: candidates.slice(1, 3),
});

const deals = (n: number) => ({
  from: "Shop Deals <deals@shop.example.test>",
  subject: `Weekly shoe discount voucher ${n}`,
  body: `Voucher ${n}: discount on shoes, sneakers and boots this weekend only. Unsubscribe anytime.`,
});

let setCounter = 0;
async function newSet(): Promise<string> {
  const res = await t.call<any>("POST", "/v1/category-sets", {
    name: `Deletion test ${++setCounter}`,
    categories: CATS,
  });
  expect(res.status).toBe(201);
  return res.body.id;
}

async function suggest(setId: string, email: unknown, extra: Record<string, unknown> = {}) {
  const res = await t.call<any>("POST", "/v1/suggestions", {
    email,
    categorySetId: setId,
    allowDelete: true,
    ...extra,
  });
  expect(res.status, JSON.stringify(res.body)).toBe(200);
  return res.body;
}

const feedback = (id: string, body: unknown) =>
  t.call<any>("POST", `/v1/suggestions/${id}/feedback`, body);

async function deleteThree(setId: string) {
  for (let i = 1; i <= 3; i++) {
    const s = await suggest(setId, deals(i));
    const res = await feedback(s.suggestionId, { email: deals(i), decision: "delete" });
    expect(res.status).toBe(201);
  }
}

describe("deleting through feedback", () => {
  it("records a deleted email as a learning example without a category", async () => {
    const setId = await newSet();
    const s = await suggest(setId, deals(1));
    expect(s.action).toBe("file");
    const res = await feedback(s.suggestionId, { email: deals(1), decision: "delete" });
    expect(res.status).toBe(201);
    expect(res.body.categoryId).toBeNull();
    const list = await t.call<any>("GET", "/v1/learning-examples?limit=1");
    expect(list.body.items[0]).toMatchObject({
      id: res.body.learningExampleId,
      categoryPath: null,
      outcome: "deleted",
      subject: deals(1).subject,
    });
    const set = await t.call<any>("GET", `/v1/category-sets/${setId}`);
    expect(set.body.categories.every((c: any) => c.exampleCount === 0)).toBe(true);
  });

  it("can be undone by deleting the learning example", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    const list = await t.call<any>("GET", "/v1/learning-examples?limit=3");
    for (const e of list.body.items) {
      expect((await t.call("DELETE", `/v1/learning-examples/${e.id}`)).status).toBe(204);
    }
    const next = await suggest(setId, deals(4));
    expect(next.action).toBe("file");
    expect(next.similarDeleted).toBe(0);
  });
});

describe("suggesting deletion from past deletions", () => {
  it("suggests deleting an email like the ones the owner deleted, with a label to keep it under", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    const s = await suggest(setId, deals(4));
    expect(s.action).toBe("delete");
    expect(s.confidence).toBe("medium"); // the model thought a label fits
    expect(s.reason).toBe("You deleted 3 similar emails before.");
    expect(s.similarDeleted).toBe(3);
    expect(s.similarPastDecisions).toBe(3);
    expect(s.similarInTrash).toBe(0);
    expect(CATS).toContain(s.category);
    // The model is never shown deleted emails as examples to follow.
    const prompt = t.stub.chatCalls
      .at(-1)!
      .messages.map((m) => m.content)
      .join("\n");
    expect(prompt).not.toMatch(/voucher \d.*=>/i);
  });

  it("is sure when the model also finds that no label fits", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    t.stub.setChat(nothingFits);
    const s = await suggest(setId, deals(4));
    expect(s.action).toBe("delete");
    expect(s.confidence).toBe("high");
    expect(s.reason).toMatch(/^No label fits well\. /);
  });

  it("never suggests deletion unless the client allows it", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    const res = await t.call<any>("POST", "/v1/suggestions", {
      email: deals(4),
      categorySetId: setId,
    });
    expect(res.body.action).toBe("file");
    expect(res.body.similarDeleted).toBe(3);
  });

  it("is at most medium sure about a label when similar emails were mostly deleted", async () => {
    const setId = await newSet();
    const bill = (n: number) => ({
      from: "Utility <bills@power.example.test>",
      subject: `Electricity invoice reminder ${n}`,
      body: `Your electricity invoice ${n} payment reminder from the power company.`,
    });
    const first = await suggest(setId, bill(1));
    expect(first).toMatchObject({ action: "file", category: "Finance", confidence: "high" });
    for (let i = 1; i <= 2; i++) {
      const s = i === 1 ? first : await suggest(setId, bill(i));
      await feedback(s.suggestionId, { email: bill(i), decision: "delete" });
    }
    // Two deletions are not a habit yet, and the model is sure of the label.
    const next = await suggest(setId, bill(3));
    expect(next).toMatchObject({ action: "file", category: "Finance", similarDeleted: 2 });
    expect(next.confidence).toBe("medium");
  });

  it("files when the owner keeps filing similar emails", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    for (let i = 5; i <= 7; i++) {
      const s = await suggest(setId, deals(i));
      await feedback(s.suggestionId, { email: deals(i), decision: "choose", category: "Shopping" });
    }
    const s = await suggest(setId, deals(8));
    expect(s.action).toBe("file");
    expect(s.category).toBe("Shopping");
  });
});

describe("feedback on a suggestion to delete", () => {
  it("confirm means delete, and counts as an accepted delete suggestion", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    const before = (await t.call<any>("GET", "/v1/stats/accuracy")).body.deleteSuggestions;
    const s = await suggest(setId, deals(4));
    expect(s.action).toBe("delete");
    const res = await feedback(s.suggestionId, { email: deals(4), decision: "confirm" });
    expect(res.status).toBe(201);
    expect(res.body.categoryId).toBeNull();
    const after = (await t.call<any>("GET", "/v1/stats/accuracy")).body.deleteSuggestions;
    expect(after).toEqual({ made: before.made + 1, accepted: before.accepted + 1 });
  });

  it("filing it anyway, even under the label it named, is a correction", async () => {
    const setId = await newSet();
    await deleteThree(setId);
    const before = (await t.call<any>("GET", "/v1/stats/accuracy")).body;
    const s = await suggest(setId, deals(4));
    expect(s.action).toBe("delete");
    const res = await feedback(s.suggestionId, {
      email: deals(4),
      decision: "choose",
      category: s.category,
    });
    expect(res.status).toBe(201);
    const list = await t.call<any>("GET", "/v1/learning-examples?limit=1");
    expect(list.body.items[0].outcome).toBe("corrected");
    const after = (await t.call<any>("GET", "/v1/stats/accuracy")).body;
    expect(after.deleteSuggestions).toEqual({
      made: before.deleteSuggestions.made + 1,
      accepted: before.deleteSuggestions.accepted,
    });
  });
});

describe("suggesting deletion from the Trash", () => {
  const inTrash = (n: number) => ({
    from: "deals@shop.example.test",
    subject: `Weekly shoe discount voucher ${n}`,
  });

  it("when no label fits, one similar email from the sender in the Trash is enough", async () => {
    const setId = await newSet();
    t.stub.setChat(nothingFits);
    const s = await suggest(setId, deals(1), { trash: [inTrash(90)] });
    expect(s.action).toBe("delete");
    expect(s.confidence).toBe("low");
    expect(s.similarInTrash).toBe(1);
    expect(s.reason).toBe("No label fits well. 1 similar email from this sender is in the Trash.");
  });

  it("ignores trashed emails from other senders and about other things", async () => {
    const setId = await newSet();
    t.stub.setChat(nothingFits);
    const s = await suggest(setId, deals(1), {
      trash: [
        { from: "Other <other@shop.example.test>", subject: "Weekly shoe discount voucher 9" },
        { from: "deals@shop.example.test", subject: "Your password was changed" },
      ],
    });
    expect(s.action).toBe("file");
    expect(s.similarInTrash).toBe(0);
  });

  it("when a label fits, it takes as many trashed emails as a habit does", async () => {
    const setId = await newSet();
    const one = await suggest(setId, deals(1), { trash: [inTrash(90)] });
    expect(one.action).toBe("file");
    const three = await suggest(setId, deals(1), {
      trash: [inTrash(90), inTrash(91), inTrash(92)],
    });
    expect(three.action).toBe("delete");
    expect(three.similarInTrash).toBe(3);
  });

  it("does not store anything from the Trash", async () => {
    const setId = await newSet();
    const before = await t.call<any>("GET", "/v1/learning-examples?limit=200");
    await suggest(setId, deals(1), { trash: [inTrash(90), inTrash(91), inTrash(92)] });
    const after = await t.call<any>("GET", "/v1/learning-examples?limit=200");
    expect(after.body.items).toEqual(before.body.items);
  });

  it("validates the Trash list", async () => {
    const setId = await newSet();
    const call = (trash: unknown) =>
      t.call<any>("POST", "/v1/suggestions", {
        email: deals(1),
        categorySetId: setId,
        allowDelete: true,
        trash,
      });
    expect((await call(Array.from({ length: 51 }, (_, i) => inTrash(i)))).status).toBe(400);
    expect((await call([{ subject: "no sender" }])).status).toBe(400);
    // Like everywhere in the API, unknown properties are dropped: a body is never used.
    expect((await call([{ ...inTrash(1), body: "secret trashed body" }])).status).toBe(200);
    expect(t.stub.embeddingInputs.some((i) => i.includes("secret trashed body"))).toBe(false);
  });
});
