// Category sets and categories (US3). Renames and moves keep ids, so learning examples stay
// attached; deletes drop the affected examples from the in-memory index at once.
import Database from "better-sqlite3";
import { dedupeCandidates, normaliseName, parsePath, PathError, validateName } from "./path.js";
import type { Embedder } from "../llm/client.js";
import type { Logger } from "../logging/logger.js";
import type { ExampleIndex } from "../learning/index.js";
import { DuplicateCategoryError, type CategoryRepo } from "../store/repos/categories.js";
import { conflict, invalid, notFound } from "../api/errors.js";

export interface SetDetail {
  id: string;
  name: string;
  isDefault: boolean;
  categories: { id: string; path: string; parentId: string | null; exampleCount: number }[];
}

export interface CategoryServiceDeps {
  categories: CategoryRepo;
  embedder: Embedder;
  index: ExampleIndex;
  logger: Logger;
}

function setName(name: string): string {
  const n = name.replace(/\s+/g, " ").trim();
  if (n.length < 1 || n.length > 80) throw invalid("set names must be 1 to 80 characters");
  return n;
}

function categoryName(name: string): string {
  try {
    return validateName(name);
  } catch (e) {
    if (e instanceof PathError) throw invalid(e.message);
    throw e;
  }
}

/** Maps SQLite constraint failures (unique names, depth triggers) to 400s. */
function translate<T>(fn: () => T, duplicateMessage: string): T {
  try {
    return fn();
  } catch (e) {
    if (e instanceof DuplicateCategoryError) throw invalid(duplicateMessage);
    if (e instanceof PathError) throw invalid(e.message);
    if (e instanceof Database.SqliteError) {
      if (e.code === "SQLITE_CONSTRAINT_UNIQUE") throw invalid(duplicateMessage);
      if (e.code === "SQLITE_CONSTRAINT_TRIGGER" || e.message.includes("max depth")) {
        throw invalid("categories are at most two levels deep");
      }
    }
    throw e;
  }
}

export class CategoryService {
  constructor(private readonly d: CategoryServiceDeps) {}

  private ownedSet(userId: string, setId: string) {
    const set = this.d.categories.getSet(userId, setId);
    if (!set) throw notFound("category set not found");
    return set;
  }

  private ownedCategory(userId: string, categoryId: string) {
    const c = this.d.categories.getCategory(userId, categoryId);
    if (!c) throw notFound("category not found");
    return c;
  }

  /** Stores name embeddings for the near-duplicate check (research R5). Best effort. */
  private async embedNames(setId: string, ids: string[]): Promise<void> {
    if (ids.length === 0) return;
    const views = this.d.categories.listCategories(setId).filter((c) => ids.includes(c.id));
    try {
      const vectors = await this.d.embedder.embed(views.map((v) => v.name));
      views.forEach((v, i) => this.d.categories.setNameEmbedding(v.id, vectors[i]!));
    } catch {
      this.d.logger.warn(
        { errorCode: "name_embedding_failed", count: views.length },
        "category name not embedded",
      );
    }
  }

  listSets(userId: string) {
    this.d.categories.getOrCreateDefaultSet(userId);
    return this.d.categories.listSets(userId).map((s) => ({
      id: s.id,
      name: s.name,
      isDefault: s.isDefault,
      categoryCount: s.categoryCount,
    }));
  }

  getSet(userId: string, setId: string): SetDetail {
    const set = this.ownedSet(userId, setId);
    const counts = this.d.categories.exampleCounts(set.id);
    return {
      id: set.id,
      name: set.name,
      isDefault: set.isDefault,
      categories: this.d.categories.listCategories(set.id).map((c) => ({
        id: c.id,
        path: c.path,
        parentId: c.parentId,
        exampleCount: counts.get(c.id) ?? 0,
      })),
    };
  }

  async createSet(userId: string, name: string, paths: string[] = []): Promise<string> {
    const n = setName(name);
    const candidates = translate(() => dedupeCandidates(paths), "duplicate category");
    // Parents come first in dedupeCandidates order, so upserting each path is enough.
    const id = translate(
      () =>
        this.d.categories.createSet(
          userId,
          n,
          candidates.map((c) => c.path),
        ),
      "a set with that name already exists",
    );
    await this.embedNames(
      id,
      this.d.categories.listCategories(id).map((c) => c.id),
    );
    return id;
  }

  renameSet(userId: string, setId: string, name: string): void {
    this.ownedSet(userId, setId);
    const n = setName(name);
    translate(() => this.d.categories.renameSet(setId, n), "a set with that name already exists");
  }

  deleteSet(userId: string, setId: string): void {
    const set = this.ownedSet(userId, setId);
    if (set.isDefault) throw invalid("the default set cannot be deleted");
    this.d.categories.deleteSet(setId);
    this.d.index.removeBySet(setId);
  }

  async addCategory(userId: string, setId: string, path: string): Promise<string> {
    this.ownedSet(userId, setId);
    const { id, created } = translate(() => {
      parsePath(path);
      return this.d.categories.addCategory(setId, path);
    }, "that category already exists");
    await this.embedNames(setId, created);
    return id;
  }

  async updateCategory(
    userId: string,
    categoryId: string,
    patch: { name?: string; parentId?: string | null },
  ): Promise<void> {
    const c = this.ownedCategory(userId, categoryId);
    if (patch.parentId !== undefined && patch.parentId !== c.parentId) {
      if (this.d.categories.childIds(c.id).length > 0) {
        throw invalid("a category with subcategories cannot be moved");
      }
      if (patch.parentId !== null) {
        const target = this.d.categories.getCategory(userId, patch.parentId);
        if (!target || target.setId !== c.setId)
          throw invalid("the new parent must be in the same set");
        if (target.parentId !== null || target.id === c.id) {
          throw invalid("categories are at most two levels deep");
        }
      }
      translate(
        () => this.d.categories.moveCategory(c.id, patch.parentId!),
        "that category already exists there",
      );
    }
    if (patch.name !== undefined) {
      const name = categoryName(patch.name);
      if (normaliseName(name) !== c.nameKey || name !== c.name) {
        translate(
          () => this.d.categories.renameCategory(c.id, name),
          "that category already exists",
        );
        await this.embedNames(c.setId, [c.id]);
      }
    }
  }

  deleteCategory(userId: string, categoryId: string, cascade: boolean): void {
    const c = this.ownedCategory(userId, categoryId);
    const children = this.d.categories.childIds(c.id);
    if (children.length > 0 && !cascade) {
      throw conflict("this category has subcategories; delete with cascade=true");
    }
    this.d.categories.deleteCategory(c.id);
    this.d.index.removeByCategory([c.id, ...children]);
  }
}
