// Contract: category set and category endpoints (contracts/http-api.md, US3)
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

interface SetDetail {
  id: string;
  name: string;
  isDefault: boolean;
  categories: { id: string; path: string; parentId: string | null; exampleCount: number }[];
}

const getSet = async (id: string) =>
  (await t.call<SetDetail>("GET", `/v1/category-sets/${id}`)).body;
const catId = (s: SetDetail, path: string) => s.categories.find((c) => c.path === path)!.id;

describe("category sets", () => {
  it("lists the default set", async () => {
    const res = await t.call<any[]>("GET", "/v1/category-sets");
    expect(res.status).toBe(200);
    expect(res.body.filter((s) => s.isDefault)).toHaveLength(1);
    expect(res.body[0]).toHaveProperty("categoryCount");
  });

  it("creates a set with categories, implied parents included", async () => {
    const res = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "Email folders",
      categories: ["Family", "Gadgets", "Travelling/TripXYZ"],
    });
    expect(res.status).toBe(201);
    const s = await getSet(res.body.id);
    expect(s.name).toBe("Email folders");
    expect(s.isDefault).toBe(false);
    expect(s.categories.map((c) => c.path).sort()).toEqual([
      "Family",
      "Gadgets",
      "Travelling",
      "Travelling/TripXYZ",
    ]);
    expect(s.categories.find((c) => c.path === "Travelling/TripXYZ")!.parentId).toBe(
      catId(s, "Travelling"),
    );
  });

  it("rejects bad set names and duplicates (case-insensitive)", async () => {
    expect((await t.call("POST", "/v1/category-sets", { name: "" })).status).toBe(400);
    expect((await t.call("POST", "/v1/category-sets", { name: "x".repeat(81) })).status).toBe(400);
    expect((await t.call("POST", "/v1/category-sets", { name: "Dupe" })).status).toBe(201);
    expect((await t.call("POST", "/v1/category-sets", { name: "dupe" })).status).toBe(400);
    expect(
      (await t.call("POST", "/v1/category-sets", { name: "Deep", categories: ["A/B/C"] })).status,
    ).toBe(400);
  });

  it("renames a set; refuses to delete the default set; deletes others", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", { name: "Temp" });
    expect((await t.call("PATCH", `/v1/category-sets/${body.id}`, { name: "Temp 2" })).status).toBe(
      200,
    );
    expect((await getSet(body.id)).name).toBe("Temp 2");
    const def = (await t.call<any[]>("GET", "/v1/category-sets")).body.find((s) => s.isDefault);
    expect((await t.call("DELETE", `/v1/category-sets/${def.id}`)).status).toBe(400);
    expect((await t.call("DELETE", `/v1/category-sets/${body.id}`)).status).toBe(204);
    expect((await t.call("GET", `/v1/category-sets/${body.id}`)).status).toBe(404);
  });

  it("adds categories with depth and duplicate checks", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "Adds",
      categories: ["Family"],
    });
    expect(
      (await t.call("POST", `/v1/category-sets/${body.id}/categories`, { path: "Family/Baby" }))
        .status,
    ).toBe(201);
    expect(
      (await t.call("POST", `/v1/category-sets/${body.id}/categories`, { path: "family/baby" }))
        .status,
    ).toBe(400);
    expect(
      (
        await t.call("POST", `/v1/category-sets/${body.id}/categories`, {
          path: "Family/Baby/Clothes",
        })
      ).status,
    ).toBe(400);
  });
});

describe("categories", () => {
  it("V7: rename keeps learning examples", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "V7",
      categories: ["Family", "Gadgets"],
    });
    const email = {
      from: "shop@example.test",
      subject: "New laptop",
      body: "Your new laptop device ships today.",
    };
    const s = (await t.call<any>("POST", "/v1/suggestions", { email, categorySetId: body.id }))
      .body;
    expect(s.category).toBe("Gadgets");
    expect(
      (
        await t.call("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
          email,
          decision: "confirm",
        })
      ).status,
    ).toBe(201);

    const before = await getSet(body.id);
    const gadgets = catId(before, "Gadgets");
    expect(before.categories.find((c) => c.id === gadgets)!.exampleCount).toBe(1);
    expect((await t.call("PATCH", `/v1/categories/${gadgets}`, { name: "Tech" })).status).toBe(200);
    const after = await getSet(body.id);
    expect(after.categories.find((c) => c.id === gadgets)).toMatchObject({
      path: "Tech",
      exampleCount: 1,
    });

    // the renamed category is what the owner's history now points to
    const again = (await t.call<any>("POST", "/v1/suggestions", { email, categorySetId: body.id }))
      .body;
    expect(again.similarPastDecisions).toBe(1);
  });

  it("rename rejects '/', duplicates and over-long names", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "Renames",
      categories: ["A", "B"],
    });
    const s = await getSet(body.id);
    for (const name of ["X/Y", "b", "x".repeat(61)]) {
      expect(
        (await t.call("PATCH", `/v1/categories/${catId(s, "A")}`, { name })).status,
        name,
      ).toBe(400);
    }
  });

  it("moves a childless category under a top-level one, but not deeper", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "Moves",
      categories: ["Family", "Family/Baby", "Kids", "Travelling"],
    });
    const s = await getSet(body.id);
    expect(
      (
        await t.call("PATCH", `/v1/categories/${catId(s, "Kids")}`, {
          parentId: catId(s, "Family"),
        })
      ).status,
    ).toBe(200);
    // target is a subcategory → depth 3
    expect(
      (
        await t.call("PATCH", `/v1/categories/${catId(s, "Travelling")}`, {
          parentId: catId(s, "Family/Baby"),
        })
      ).status,
    ).toBe(400);
    // category with children cannot move
    expect(
      (
        await t.call("PATCH", `/v1/categories/${catId(s, "Family")}`, {
          parentId: catId(s, "Travelling"),
        })
      ).status,
    ).toBe(400);
    // back to top level
    expect(
      (await t.call("PATCH", `/v1/categories/${catId(s, "Kids")}`, { parentId: null })).status,
    ).toBe(200);
    expect((await getSet(body.id)).categories.find((c) => c.path === "Kids")!.parentId).toBeNull();
  });

  it("delete needs cascade when there are children", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "Deletes",
      categories: ["Family/Baby", "Gadgets"],
    });
    const s = await getSet(body.id);
    expect((await t.call("DELETE", `/v1/categories/${catId(s, "Family")}`)).status).toBe(409);
    expect(
      (await t.call("DELETE", `/v1/categories/${catId(s, "Family")}?cascade=true`)).status,
    ).toBe(204);
    expect((await getSet(body.id)).categories.map((c) => c.path)).toEqual(["Gadgets"]);
    expect((await t.call("DELETE", `/v1/categories/${catId(s, "Gadgets")}`)).status).toBe(204);
  });

  it("a removed category is never suggested from its set", async () => {
    const { body } = await t.call<{ id: string }>("POST", "/v1/category-sets", {
      name: "Removed",
      categories: ["Family", "Gadgets"],
    });
    const s = await getSet(body.id);
    await t.call("DELETE", `/v1/categories/${catId(s, "Gadgets")}`);
    const email = {
      from: "shop@example.test",
      subject: "New laptop",
      body: "Your new laptop device ships today.",
    };
    const res = (await t.call<any>("POST", "/v1/suggestions", { email, categorySetId: body.id }))
      .body;
    expect(res.category).not.toBe("Gadgets");
    expect(res.runnersUp.map((r: any) => r.path)).not.toContain("Gadgets");
  });

  it("404 for another user's or unknown category", async () => {
    expect(
      (await t.call("PATCH", "/v1/categories/01H00000000000000000000000", { name: "X" })).status,
    ).toBe(404);
  });
});
