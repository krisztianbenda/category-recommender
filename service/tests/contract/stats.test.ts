// Contract: GET /v1/stats/accuracy (FR-020)
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startTestApp, type TestApp } from "../helpers/app.js";
import { keywordChat } from "../helpers/keyword-chat.js";

let t: TestApp;

beforeAll(async () => {
  t = await startTestApp();
  t.stub.setChat(keywordChat);
});
afterAll(async () => t.close());

const email = (i: number) => ({
  from: `p${i}@example.test`,
  subject: `family note ${i}`,
  body: `family news number ${i}`,
});
const booking = {
  from: "b@travel.example.test",
  subject: "Hotel booking",
  body: "Hotel reservation confirmed.",
};

describe("GET /v1/stats/accuracy", () => {
  it("returns zeros before any decision", async () => {
    const res = await t.call<any>("GET", "/v1/stats/accuracy");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      window: 100,
      decisions: 0,
      acceptedWithoutCorrection: null,
      byConfidence: { high: null, medium: null, low: null },
      newProposals: { made: 0, accepted: 0 },
    });
  });

  it("counts confirmed and accepted_new as accepted, corrected as not", async () => {
    for (let i = 0; i < 3; i++) {
      const s = (
        await t.call<any>("POST", "/v1/suggestions", {
          email: email(i),
          categories: ["Family", "Gadgets"],
        })
      ).body;
      const decision =
        i < 2 ? { decision: "confirm" } : { decision: "choose", category: "Gadgets" };
      expect(
        (
          await t.call("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
            email: email(i),
            ...decision,
          })
        ).status,
      ).toBe(201);
    }
    const s = (
      await t.call<any>("POST", "/v1/suggestions", { email: booking, categories: ["Travelling"] })
    ).body;
    expect(s.isNew).toBe(true);
    await t.call("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
      email: booking,
      decision: "confirm",
    });

    const res = await t.call<any>("GET", "/v1/stats/accuracy?window=50");
    expect(res.status).toBe(200);
    expect(res.body.window).toBe(50);
    expect(res.body.decisions).toBe(4);
    expect(res.body.acceptedWithoutCorrection).toBeCloseTo(3 / 4);
    expect(res.body.newProposals).toEqual({ made: 1, accepted: 1 });
    expect(res.body.byConfidence.low).toBe(1); // the new proposal was low and accepted
  });

  it("only allows window 50 or 100", async () => {
    expect((await t.call("GET", "/v1/stats/accuracy?window=7")).status).toBe(400);
  });
});
