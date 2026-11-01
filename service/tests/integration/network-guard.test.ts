// Constitution quality gate / SC-006: the full flow makes no outbound connection other than the
// local model runtime and the test server itself.
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startTestApp, type TestApp } from "../helpers/app.js";
import { keywordChat } from "../helpers/keyword-chat.js";
import { installNetworkGuard, type NetworkGuard } from "../helpers/network-guard.js";

let t: TestApp;
let guard: NetworkGuard;

beforeAll(async () => {
  t = await startTestApp();
  t.stub.setChat(keywordChat);
  guard = installNetworkGuard(() => [
    { host: "127.0.0.1", port: t.stub.port },
    { host: "127.0.0.1", port: t.port },
  ]);
});

afterAll(async () => {
  guard.uninstall();
  await t.close();
});

describe("network guard", () => {
  it("blocks anything that is not an allowed local endpoint", async () => {
    const { request } = await import("undici");
    await expect(request("http://192.0.2.1:80/")).rejects.toThrow(/network guard/);
    expect(guard.violations).toContainEqual({ host: "192.0.2.1", port: 80 });
    guard.violations.length = 0;
  });

  it("runs suggest → feedback → learn → rename → delete with no unexpected connection", async () => {
    const email = {
      from: "GadgetMart <orders@gadgetmart.example.test>",
      subject: "GadgetMart receipt",
      body: "Receipt for your new device, paid by card.",
    };
    const cats = ["Family", "Gadgets", "Finance"];

    const s1 = (await t.call<any>("POST", "/v1/suggestions", { email, categories: cats })).body;
    const fb = await t.call<any>("POST", `/v1/suggestions/${s1.suggestionId}/feedback`, {
      email,
      decision: "choose",
      category: "Finance",
    });
    expect(fb.status).toBe(201);

    const s2 = (await t.call<any>("POST", "/v1/suggestions", { email, categories: cats })).body;
    expect(s2.similarPastDecisions).toBe(1);

    expect(
      (await t.call("PATCH", `/v1/categories/${fb.body.categoryId}`, { name: "Money" })).status,
    ).toBe(200);
    expect(
      (await t.call("DELETE", `/v1/learning-examples/${fb.body.learningExampleId}`)).status,
    ).toBe(204);
    expect((await t.call("DELETE", "/v1/me/data", { confirm: "DELETE ALL" })).status).toBe(204);
    expect((await t.call("GET", "/v1/health")).status).toBe(200);

    expect(guard.attempts.length).toBeGreaterThan(0); // the guard really observed traffic
    expect(guard.violations).toEqual([]);
  });
});
