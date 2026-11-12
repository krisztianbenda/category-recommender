// Contract: learned-data endpoints (contracts/http-api.md, US4, SC-007)
import { describe, expect, it } from "vitest";
import { useTestApp } from "../helpers/app.js";

const t = useTestApp();

const CATS = ["Family", "Gadgets", "Finance"];
const receipt = (n: number) => ({
  from: "GadgetMart <orders@gadgetmart.example.test>",
  subject: `GadgetMart receipt ${n}`,
  body: `Receipt for your new device, order ${n}, paid by card. SYNTHETIC-SNIPPET-${n}`,
});

async function learn(n: number, category = "Finance") {
  const s = (await t.call<any>("POST", "/v1/suggestions", { email: receipt(n), categories: CATS }))
    .body;
  const res = await t.call<any>("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
    email: receipt(n),
    decision: "choose",
    category,
  });
  expect(res.status).toBe(201);
  return res.body as { learningExampleId: string; categoryId: string };
}

const similar = async () =>
  (await t.call<any>("POST", "/v1/suggestions", { email: receipt(99), categories: CATS })).body
    .similarPastDecisions as number;

describe("learned data", () => {
  it("lists examples with paging and the contract shape", async () => {
    const ids = [await learn(1), await learn(2), await learn(3)];
    const page1 = await t.call<any>("GET", "/v1/learning-examples?limit=2");
    expect(page1.status).toBe(200);
    expect(page1.body.items).toHaveLength(2);
    expect(page1.body.items[0]).toEqual({
      id: expect.any(String),
      categoryPath: "Finance",
      sender: expect.any(String),
      subject: expect.any(String),
      snippet: expect.stringContaining("SYNTHETIC-SNIPPET-"),
      outcome: "corrected",
      decidedAt: expect.any(String),
    });
    const page2 = await t.call<any>(
      "GET",
      `/v1/learning-examples?limit=2&cursor=${page1.body.nextCursor}`,
    );
    expect(page2.body.items).toHaveLength(1);
    expect(page2.body.nextCursor).toBeNull();
    const all = [...page1.body.items, ...page2.body.items].map((i: any) => i.id).sort();
    expect(all).toEqual(ids.map((i) => i.learningExampleId).sort());

    const byCat = await t.call<any>(
      "GET",
      `/v1/learning-examples?categoryId=${ids[0]!.categoryId}`,
    );
    expect(byCat.body.items).toHaveLength(3);
  });

  it("V8: deleting one example removes it and its influence at once", async () => {
    const before = await similar();
    const list = (await t.call<any>("GET", "/v1/learning-examples")).body.items;
    const res = await t.call("DELETE", `/v1/learning-examples/${list[0].id}`);
    expect(res.status).toBe(204);
    expect(
      (await t.call<any>("GET", "/v1/learning-examples")).body.items.map((i: any) => i.id),
    ).not.toContain(list[0].id);
    expect(await similar()).toBe(before - 1);
    expect((await t.call("DELETE", `/v1/learning-examples/${list[0].id}`)).status).toBe(404);
  });

  it("deletes all examples of a category", async () => {
    const { categoryId } = await learn(4);
    expect((await t.call("DELETE", `/v1/categories/${categoryId}/learning-examples`)).status).toBe(
      204,
    );
    expect(
      (await t.call<any>("GET", `/v1/learning-examples?categoryId=${categoryId}`)).body.items,
    ).toHaveLength(0);
    expect(await similar()).toBe(0);
  });

  it("delete-all requires the typed confirmation", async () => {
    expect((await t.call("DELETE", "/v1/me/data", {})).status).toBe(400);
    expect((await t.call("DELETE", "/v1/me/data", { confirm: "delete all" })).status).toBe(400);
  });

  it("delete-all removes every row for the user and starts fresh", async () => {
    await learn(5);
    await t.call("POST", "/v1/category-sets", { name: "Mine", categories: ["Family"] });
    const res = await t.call("DELETE", "/v1/me/data", { confirm: "DELETE ALL" });
    expect(res.status).toBe(204);

    const db = t.app.ctx.db;
    const count = (sql: string) => (db.prepare(sql).get("owner") as { n: number }).n;
    expect(count("SELECT count(*) n FROM learning_examples WHERE user_id = ?")).toBe(0);
    expect(count("SELECT count(*) n FROM decisions WHERE user_id = ?")).toBe(0);
    expect(
      count(
        "SELECT count(*) n FROM categories c JOIN category_sets s ON s.id = c.set_id WHERE s.user_id = ?",
      ),
    ).toBe(0);
    expect(count("SELECT count(*) n FROM category_sets WHERE user_id = ? AND is_default = 0")).toBe(
      0,
    );

    // a default set exists again for the next request, and suggestions work with no history
    const sets = await t.call<any[]>("GET", "/v1/category-sets");
    expect(sets.body.filter((s) => s.isDefault)).toHaveLength(1);
    expect(await similar()).toBe(0);
    const stats = await t.call<any>("GET", "/v1/stats/accuracy");
    expect(stats.body.decisions).toBe(0);
  });
});
