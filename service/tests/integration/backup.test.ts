// Backup → restore round trip (FR-021, quickstart section 5). Uses a pass-through stand-in for
// `age` so the flow is tested without the real tool; encryption itself is age's job.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import Database from "better-sqlite3";
import { backup } from "../../src/cli/backup.js";
import { restore } from "../../src/cli/restore.js";
import { loadConfig } from "../../src/config/load.js";
import type { Config } from "../../src/config/schema.js";
import { startTestApp, type TestApp } from "../helpers/app.js";
import { keywordChat } from "../helpers/keyword-chat.js";

let t: TestApp;
let tmp: string;

beforeAll(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-bk-"));
  const fakeAge = path.join(tmp, "fake-age.sh");
  // Supports `age -r R -o OUT IN` and `age -d -i ID -o OUT IN` by copying IN to OUT.
  fs.writeFileSync(
    fakeAge,
    '#!/bin/sh\nout=""; while [ $# -gt 1 ]; do case "$1" in -o) out="$2"; shift 2;; -r|-i) shift 2;; *) shift;; esac; done; cp "$1" "$out"\n',
    { mode: 0o755 },
  );
  process.env.CATREC_AGE_BIN = fakeAge;
  t = await startTestApp();
  t.stub.setChat(keywordChat);
});

afterAll(async () => {
  delete process.env.CATREC_AGE_BIN;
  await t.close();
  fs.rmSync(tmp, { recursive: true, force: true });
});

const counts = (dbFile: string) => {
  const db = new Database(dbFile, { readonly: true });
  try {
    const n = (sql: string) => (db.prepare(sql).get() as { n: number }).n;
    return {
      examples: n("SELECT count(*) n FROM learning_examples"),
      decisions: n("SELECT count(*) n FROM decisions"),
      categories: n("SELECT count(*) n FROM categories"),
      sets: n("SELECT count(*) n FROM category_sets"),
    };
  } finally {
    db.close();
  }
};

describe("backup and restore", () => {
  it("round-trips category sets, examples and accuracy history to a fresh data dir", async () => {
    const email = {
      from: "a@example.test",
      subject: "family lunch",
      body: "family lunch on sunday",
    };
    const s = (
      await t.call<any>("POST", "/v1/suggestions", { email, categories: ["Family", "Gadgets"] })
    ).body;
    await t.call("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
      email,
      decision: "confirm",
    });
    await t.call("POST", "/v1/category-sets", {
      name: "Folders",
      categories: ["Work", "Work/Projects"],
    });

    t.writeConfig((c: any) => (c.backup.ageRecipient = "age1placeholder"));
    const config = loadConfig(t.configFile);
    const out = path.join(tmp, "backup.age");
    await backup(config, t.configFile, out);
    expect(fs.statSync(out).mode & 0o777).toBe(0o600);

    const freshDir = path.join(tmp, "fresh-state");
    const freshConfig: Config = { ...config, storage: { ...config.storage, dataDir: freshDir } };
    const r = restore(freshConfig, out, path.join(tmp, "identity.txt"));
    expect(r.manifest.embeddingModel).toBe("stub-embed");
    expect(r.manifest.migrations).toContain("001_init.sql");

    const original = counts(path.join(t.dataDir, "catrec.db"));
    expect(counts(path.join(freshDir, "catrec.db"))).toEqual(original);
    expect(original.examples).toBe(1);
    expect(fs.existsSync(path.join(freshDir, "restored-config.yaml"))).toBe(true);
  });

  it("refuses to overwrite an existing database without --force, keeps the old one with it", async () => {
    const config = loadConfig(t.configFile);
    const out = path.join(tmp, "backup.age");
    const target: Config = {
      ...config,
      storage: { ...config.storage, dataDir: path.join(tmp, "fresh-state") },
    };
    expect(() => restore(target, out, "id")).toThrow(/--force/);
    const r = restore(target, out, "id", { force: true });
    expect(r.previousMovedTo).toMatch(/before-restore-/);
    expect(fs.existsSync(r.previousMovedTo!)).toBe(true);
  });

  it("requires a recipient", async () => {
    const config = loadConfig(t.configFile);
    const noRecipient: Config = { ...config, backup: { ageRecipient: null } };
    await expect(backup(noRecipient, t.configFile, path.join(tmp, "x.age"))).rejects.toThrow(
      /ageRecipient/,
    );
  });
});
