// End to end: the built service (dist/src/main.js, as scripts/run-local.sh starts it) in local
// mode, with the stub model, replaying the synthetic session in fixtures/synthetic/e2e. Covers
// startup, the web UI, category sets, suggestions, every kind of feedback, learning habits,
// suggesting deletion, learned data, a restart, deleting all data, and logs without content.
// Run with `npm run test:e2e`, which builds first.
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { stringify } from "yaml";
import type { Email, Suggestion } from "../../src/suggest/types.js";
import { callJson } from "../helpers/http.js";
import { keywordChat } from "../helpers/keyword-chat.js";
import { startStubLlm, type StubLlm } from "../helpers/stub-llm.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MAIN = path.resolve(HERE, "../../dist/src/main.js");
const SESSION = path.resolve(HERE, "../../../fixtures/synthetic/e2e/session.json");

interface Step {
  id: string;
  email: Email;
  expect?: {
    action?: "file" | "delete";
    category?: string;
    isNew?: boolean;
    newCategoryParent?: string | null;
    minSimilarPastDecisions?: number;
  };
  owner: { file: string } | { fileNew: { parent: string | null; name: string } } | { delete: true };
}
interface Session {
  categorySet: { name: string; categories: string[] };
  steps: Step[];
}

const session = JSON.parse(fs.readFileSync(SESSION, "utf8")) as Session;
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

let stub: StubLlm;
let root: string;
let dataDir: string;
let port: number;
let service: { child: ChildProcess; exited: Promise<unknown>; done: boolean } | undefined;
let setId: string;

const call = <T = any>(method: string, url: string, body?: unknown) =>
  callJson<T>(method, `http://127.0.0.1:${port}${url}`, body);

async function freePort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as net.AddressInfo;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startService(): Promise<void> {
  const child = spawn(process.execPath, [MAIN], {
    env: { ...process.env, CATREC_CONFIG: path.join(root, "config.yaml") },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr!.on("data", (chunk) => (stderr += chunk));
  // The exit event also covers a death by signal, when exitCode stays null.
  const current = { child, exited: once(child, "exit"), done: false };
  void current.exited.then(() => (current.done = true));
  service = current;
  for (let i = 0; i < 150; i++) {
    if (current.done) throw new Error(`the service exited: ${stderr}`);
    const health = await call("GET", "/v1/health").catch(() => null);
    if (health?.status === 200) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`the service did not start: ${stderr}`);
}

async function stopService(): Promise<void> {
  const current = service;
  service = undefined;
  if (!current || current.done) return;
  current.child.kill("SIGTERM");
  await current.exited;
}

/** The owner's decision for a suggestion, as the feedback request body. */
function decision(step: Step, s: Suggestion): Record<string, unknown> {
  const owner = step.owner;
  if ("delete" in owner) return { decision: s.action === "delete" ? "confirm" : "delete" };
  if ("fileNew" in owner) return { decision: "accept_new", newCategory: owner.fileNew };
  const agreed = s.action === "file" && !s.isNew && same(s.category, owner.file);
  return agreed ? { decision: "confirm" } : { decision: "choose", category: owner.file };
}

const suggest = (email: Email, source: Record<string, unknown>) =>
  call<Suggestion>("POST", "/v1/suggestions", { email, ...source, allowDelete: true });

beforeAll(async () => {
  if (!fs.existsSync(MAIN)) throw new Error("build the service first: npm run build");
  stub = await startStubLlm();
  stub.setChat(keywordChat);
  root = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-e2e-"));
  dataDir = path.join(root, "state");
  port = await freePort();
  fs.writeFileSync(
    path.join(root, "config.yaml"),
    stringify({
      version: 1,
      server: { bindAddress: "127.0.0.1", port },
      storage: { dataDir, encryption: "external-volume" },
      llm: { baseUrl: stub.url, model: "stub-llm", requestTimeoutSeconds: 5 },
      embeddings: { baseUrl: stub.url, model: "stub-embed" },
      logging: { level: "info", retentionDays: 1 },
    }),
  );
  await startService();
});

afterAll(async () => {
  await stopService();
  await stub?.close();
  if (root) fs.rmSync(root, { recursive: true, force: true });
});

describe("the built service starts in local mode", () => {
  it("reports both model servers as up", async () => {
    const res = await call("GET", "/v1/health");
    expect(res.body).toEqual({ status: "ok", llm: "up", embeddings: "up" });
  });

  it("serves the web UI", async () => {
    const res = await fetch(`http://127.0.0.1:${port}/`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/text\/html/);
    expect(await res.text()).toContain('src="/app.js"');
    expect((await fetch(`http://127.0.0.1:${port}/app.js`)).status).toBe(200);
  });

  it("creates the session's category set", async () => {
    const res = await call<{ id: string }>("POST", "/v1/category-sets", session.categorySet);
    expect(res.status).toBe(201);
    setId = res.body.id;
  });
});

describe("the owner's session, step by step", () => {
  for (const step of session.steps) {
    it(step.id, async () => {
      const res = await suggest(step.email, { categorySetId: setId });
      expect(res.status).toBe(200);
      const s = res.body;
      const e = step.expect ?? {};
      if (e.action !== undefined) expect(s.action).toBe(e.action);
      if (e.category !== undefined) expect(s.category.toLowerCase()).toBe(e.category.toLowerCase());
      if (e.isNew !== undefined) expect(s.isNew).toBe(e.isNew);
      if (e.newCategoryParent !== undefined) {
        expect(s.newCategory?.parent ?? null).toBe(e.newCategoryParent);
      }
      if (e.minSimilarPastDecisions !== undefined) {
        expect(s.similarPastDecisions).toBeGreaterThanOrEqual(e.minSimilarPastDecisions);
      }

      const fb = await call("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
        email: step.email,
        ...decision(step, s),
      });
      expect(fb.status).toBe(201);
    });
  }
});

describe("after the session", () => {
  const habit = session.steps.find((s) => s.id === "standup-4-learned")!;

  it("lists every decision as learned data, deleted emails without a category", async () => {
    const res = await call<{ items: { outcome: string; categoryPath: string | null }[] }>(
      "GET",
      "/v1/learning-examples?limit=200",
    );
    expect(res.body.items).toHaveLength(session.steps.length);
    const deletions = session.steps.filter((s) => "delete" in s.owner).length;
    const deleted = res.body.items.filter((i) => i.outcome === "deleted");
    expect(deleted).toHaveLength(deletions);
    expect(deleted.every((i) => i.categoryPath === null)).toBe(true);
  });

  it("counts every decision in the accuracy stats", async () => {
    const res = await call<{ decisions: number }>("GET", "/v1/stats/accuracy?window=50");
    expect(res.body.decisions).toBe(session.steps.length);
  });

  it("created the accepted new category in the set", async () => {
    const res = await call<{ categories: { path: string; exampleCount: number }[] }>(
      "GET",
      `/v1/category-sets/${setId}`,
    );
    const trip = res.body.categories.find((c) => same(c.path, "Travelling/Trip Lisbon"));
    expect(trip?.exampleCount).toBe(2);
  });

  it("keeps what it learned across a restart", async () => {
    await stopService();
    await startService();
    const s = (await suggest(habit.email, { categorySetId: setId })).body;
    expect(s.category).toBe("Work");
    expect(s.similarPastDecisions).toBeGreaterThanOrEqual(3);
  });

  it("forgets everything when the owner deletes all their data", async () => {
    const del = await call("DELETE", "/v1/me/data", { confirm: "DELETE ALL" });
    expect(del.status).toBe(204);
    const list = await call<{ items: unknown[] }>("GET", "/v1/learning-examples");
    expect(list.body.items).toHaveLength(0);
    const s = (await suggest(habit.email, { categories: session.categorySet.categories })).body;
    expect(s.similarPastDecisions).toBe(0);
  });

  it("wrote logs with no email content in them", async () => {
    await stopService();
    const dir = path.join(dataDir, "logs");
    const logs = fs
      .readdirSync(dir)
      .map((f) => fs.readFileSync(path.join(dir, f), "utf8"))
      .join("\n");
    expect(logs).toMatch(/"suggestion"/);
    for (const step of session.steps) {
      for (const text of [step.email.from, step.email.subject, step.email.body.slice(0, 40)]) {
        expect(logs).not.toContain(text);
      }
    }
    for (const path of session.categorySet.categories) expect(logs).not.toContain(`"${path}"`);
  });
});
