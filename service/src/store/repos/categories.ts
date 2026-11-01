import type { Db } from "../db.js";
import { formatPath, normaliseName, parsePath, pathKey } from "../../categories/path.js";
import { fromBlob, newId, nowIso, toBlob } from "../util.js";

export class DuplicateCategoryError extends Error {
  constructor() {
    super("that category already exists");
    this.name = "DuplicateCategoryError";
  }
}

export interface SetRow {
  id: string;
  userId: string;
  name: string;
  isDefault: boolean;
}

export interface CategoryView {
  id: string;
  setId: string;
  parentId: string | null;
  name: string;
  nameKey: string;
  path: string;
  key: string;
  nameEmbedding: Float32Array | null;
}

interface RawSet {
  id: string;
  user_id: string;
  name: string;
  is_default: number;
}

interface RawCategory {
  id: string;
  set_id: string;
  parent_id: string | null;
  name: string;
  name_key: string;
  name_embedding: Buffer | null;
}

const toSet = (r: RawSet): SetRow => ({
  id: r.id,
  userId: r.user_id,
  name: r.name,
  isDefault: r.is_default === 1,
});

export class CategoryRepo {
  constructor(private readonly db: Db) {}

  ensureUser(id: string): void {
    this.db.prepare("INSERT OR IGNORE INTO users (id, created_at) VALUES (?, ?)").run(id, nowIso());
  }

  getOrCreateDefaultSet(userId: string): SetRow {
    const existing = this.db
      .prepare("SELECT * FROM category_sets WHERE user_id = ? AND is_default = 1")
      .get(userId) as RawSet | undefined;
    if (existing) return toSet(existing);
    this.ensureUser(userId);
    const id = newId();
    const now = nowIso();
    this.db
      .prepare(
        "INSERT INTO category_sets (id, user_id, name, name_key, is_default, created_at, updated_at) VALUES (?, ?, 'Default', 'default', 1, ?, ?)",
      )
      .run(id, userId, now, now);
    return { id, userId, name: "Default", isDefault: true };
  }

  getSet(userId: string, setId: string): SetRow | undefined {
    const r = this.db
      .prepare("SELECT * FROM category_sets WHERE id = ? AND user_id = ?")
      .get(setId, userId) as RawSet | undefined;
    return r ? toSet(r) : undefined;
  }

  listCategories(setId: string): CategoryView[] {
    const rows = this.db
      .prepare("SELECT * FROM categories WHERE set_id = ? ORDER BY parent_id IS NOT NULL, id")
      .all(setId) as RawCategory[];
    const byId = new Map(rows.map((r) => [r.id, r]));
    return rows.map((r) => {
      const parent = r.parent_id ? byId.get(r.parent_id) : undefined;
      const path = parent ? `${parent.name}/${r.name}` : r.name;
      return {
        id: r.id,
        setId: r.set_id,
        parentId: r.parent_id,
        name: r.name,
        nameKey: r.name_key,
        path,
        key: parent ? `${parent.name_key}/${r.name_key}` : r.name_key,
        nameEmbedding: r.name_embedding ? fromBlob(r.name_embedding) : null,
      };
    });
  }

  getCategory(userId: string, categoryId: string): CategoryView | undefined {
    const row = this.db
      .prepare(
        "SELECT c.set_id FROM categories c JOIN category_sets s ON s.id = c.set_id WHERE c.id = ? AND s.user_id = ?",
      )
      .get(categoryId, userId) as { set_id: string } | undefined;
    if (!row) return undefined;
    return this.listCategories(row.set_id).find((c) => c.id === categoryId);
  }

  findByPath(setId: string, path: string): CategoryView | undefined {
    const key = pathKey(formatPath(parsePath(path)));
    return this.listCategories(setId).find((c) => c.key === key);
  }

  private insertCategory(setId: string, parentId: string | null, name: string): string {
    const id = newId();
    const now = nowIso();
    this.db
      .prepare(
        "INSERT INTO categories (id, set_id, parent_id, name, name_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(id, setId, parentId, name, normaliseName(name), now, now);
    return id;
  }

  /** Creates any missing part of `path` (parent first) and returns the leaf id. */
  upsertPath(setId: string, path: string): { id: string; created: string[] } {
    const p = parsePath(path);
    const created: string[] = [];
    return this.db.transaction(() => {
      const findChild = (parentId: string | null, name: string) =>
        this.db
          .prepare(
            "SELECT id FROM categories WHERE set_id = ? AND coalesce(parent_id, '') = ? AND name_key = ?",
          )
          .get(setId, parentId ?? "", normaliseName(name)) as { id: string } | undefined;
      let parentId: string | null = null;
      if (p.parent !== null) {
        parentId = findChild(null, p.parent)?.id ?? null;
        if (!parentId) {
          parentId = this.insertCategory(setId, null, p.parent);
          created.push(parentId);
        }
      }
      let id = findChild(parentId, p.name)?.id;
      if (!id) {
        id = this.insertCategory(setId, parentId, p.name);
        created.push(id);
      }
      return { id, created };
    })();
  }

  listSets(userId: string): (SetRow & { categoryCount: number })[] {
    const rows = this.db
      .prepare(
        `SELECT s.*, (SELECT count(*) FROM categories c WHERE c.set_id = s.id) AS category_count
         FROM category_sets s WHERE s.user_id = ? ORDER BY s.is_default DESC, s.name`,
      )
      .all(userId) as (RawSet & { category_count: number })[];
    return rows.map((r) => ({ ...toSet(r), categoryCount: r.category_count }));
  }

  /** Throws SqliteError (SQLITE_CONSTRAINT_UNIQUE) on a duplicate name. */
  createSet(userId: string, name: string, paths: string[] = []): string {
    const id = newId();
    const now = nowIso();
    this.db.transaction(() => {
      this.db
        .prepare(
          "INSERT INTO category_sets (id, user_id, name, name_key, is_default, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)",
        )
        .run(id, userId, name, normaliseName(name), now, now);
      for (const p of paths) this.upsertPath(id, p);
    })();
    return id;
  }

  renameSet(setId: string, name: string): void {
    this.db
      .prepare("UPDATE category_sets SET name = ?, name_key = ?, updated_at = ? WHERE id = ?")
      .run(name, normaliseName(name), nowIso(), setId);
  }

  deleteSet(setId: string): void {
    this.db.prepare("DELETE FROM category_sets WHERE id = ? AND is_default = 0").run(setId);
  }

  /** Adds a new category; throws SqliteError on a duplicate. Missing parents are created. */
  addCategory(setId: string, path: string): { id: string; created: string[] } {
    const existing = this.findByPath(setId, path);
    if (existing) throw new DuplicateCategoryError();
    return this.upsertPath(setId, path);
  }

  /** Renames in place: the id (and so every learning example) is unchanged. */
  renameCategory(categoryId: string, name: string): void {
    this.db
      .prepare(
        "UPDATE categories SET name = ?, name_key = ?, name_embedding = NULL, updated_at = ? WHERE id = ?",
      )
      .run(name, normaliseName(name), nowIso(), categoryId);
  }

  /** Moves a childless category under a top-level one (or to the top level). Triggers enforce depth. */
  moveCategory(categoryId: string, parentId: string | null): void {
    this.db
      .prepare("UPDATE categories SET parent_id = ?, updated_at = ? WHERE id = ?")
      .run(parentId, nowIso(), categoryId);
  }

  childIds(categoryId: string): string[] {
    return (
      this.db.prepare("SELECT id FROM categories WHERE parent_id = ?").all(categoryId) as {
        id: string;
      }[]
    ).map((r) => r.id);
  }

  /** Deletes the category (and its children, by FK cascade) with all their learning examples. */
  deleteCategory(categoryId: string): void {
    this.db.prepare("DELETE FROM categories WHERE id = ?").run(categoryId);
  }

  exampleCounts(setId: string): Map<string, number> {
    const rows = this.db
      .prepare(
        "SELECT category_id, count(*) AS n FROM learning_examples WHERE set_id = ? GROUP BY category_id",
      )
      .all(setId) as { category_id: string; n: number }[];
    return new Map(rows.map((r) => [r.category_id, r.n]));
  }

  setNameEmbedding(categoryId: string, embedding: Float32Array): void {
    this.db
      .prepare("UPDATE categories SET name_embedding = ? WHERE id = ?")
      .run(toBlob(embedding), categoryId);
  }
}
