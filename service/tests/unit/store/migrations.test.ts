// Migration 002 rebuilds learning_examples. Existing rows, and the decisions that point at them,
// must come through unchanged; foreign key actions must not run while the old table is dropped.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { migrate, openDb, type Db } from "../../../src/store/db.js";

const MIGRATIONS = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../src/store/migrations",
);

const roots: string[] = [];
afterEach(() => {
  for (const r of roots.splice(0)) fs.rmSync(r, { recursive: true, force: true });
});

function tempDb(): { db: Db; root: string } {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-migrate-"));
  roots.push(root);
  return { db: openDb(path.join(root, "catrec.db")), root };
}

/** A database at schema 001 with one synthetic example and its decision. */
function atSchema001(): Db {
  const { db, root } = tempDb();
  const only001 = path.join(root, "m001");
  fs.mkdirSync(only001);
  fs.copyFileSync(path.join(MIGRATIONS, "001_init.sql"), path.join(only001, "001_init.sql"));
  migrate(db, only001);
  const t = "2026-11-01T10:00:00.000Z";
  db.prepare("INSERT INTO users VALUES ('owner', ?)").run(t);
  db.prepare(
    "INSERT INTO category_sets (id, user_id, name, name_key, is_default, created_at, updated_at) VALUES ('S', 'owner', 'Default', 'default', 1, ?, ?)",
  ).run(t, t);
  db.prepare(
    "INSERT INTO categories (id, set_id, parent_id, name, name_key, created_at, updated_at) VALUES ('C', 'S', NULL, 'Family', 'family', ?, ?)",
  ).run(t, t);
  db.prepare(
    `INSERT INTO learning_examples (id, user_id, set_id, category_id, suggested_category_path, outcome,
     sender, subject, snippet, embedding, embedding_model, decided_at)
     VALUES ('E', 'owner', 'S', 'C', 'Family', 'confirmed', 'dad@example.test', 'Lunch', 'Sunday', x'00000000', 'm', ?)`,
  ).run(t);
  db.prepare(
    "INSERT INTO decisions (id, user_id, learning_example_id, outcome, confidence, was_new_proposal, decided_at) VALUES ('D', 'owner', 'E', 'confirmed', 'high', 0, ?)",
  ).run(t);
  return db;
}

const insertExample = (db: Db, id: string, categoryId: string | null, outcome: string) =>
  db
    .prepare(
      `INSERT INTO learning_examples (id, user_id, set_id, category_id, suggested_category_path, outcome,
       sender, subject, snippet, embedding, embedding_model, decided_at)
       VALUES (?, 'owner', 'S', ?, 'Family', ?, 's', 'x', 'y', x'00000000', 'm', '2026-11-02T00:00:00.000Z')`,
    )
    .run(id, categoryId, outcome);

describe("migration 002 (deletions)", () => {
  it("keeps existing examples and the decisions that point at them", () => {
    const db = atSchema001();
    expect(migrate(db)).toEqual(["002_deletions.sql"]);
    expect(db.prepare("SELECT id, category_id, outcome FROM learning_examples").all()).toEqual([
      { id: "E", category_id: "C", outcome: "confirmed" },
    ]);
    expect(
      db.prepare("SELECT learning_example_id, was_delete_suggestion FROM decisions").get(),
    ).toEqual({ learning_example_id: "E", was_delete_suggestion: 0 });
    expect(db.pragma("foreign_keys", { simple: true })).toBe(1);
    expect(db.pragma("foreign_key_check")).toEqual([]);
  });

  it("allows a deleted email without a category, and only then", () => {
    const db = atSchema001();
    migrate(db);
    insertExample(db, "DEL", null, "deleted");
    expect(() => insertExample(db, "BAD1", "C", "deleted")).toThrow(/CHECK/);
    expect(() => insertExample(db, "BAD2", null, "confirmed")).toThrow(/CHECK/);
  });

  it("still cascades and nulls as before once it has run", () => {
    const db = atSchema001();
    migrate(db);
    db.prepare("DELETE FROM categories WHERE id = 'C'").run();
    expect(db.prepare("SELECT count(*) AS n FROM learning_examples").get()).toEqual({ n: 0 });
    expect(db.prepare("SELECT learning_example_id FROM decisions").get()).toEqual({
      learning_example_id: null,
    });
  });

  it("leaves foreign keys as they were when there is nothing to do", () => {
    const { db } = tempDb();
    migrate(db);
    expect(migrate(db)).toEqual([]);
    expect(db.pragma("foreign_keys", { simple: true })).toBe(1);
  });
});
