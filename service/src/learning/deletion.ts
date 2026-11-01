// Owner-initiated deletion of learned data (US4, FR-011, SC-007). Each operation runs in one
// transaction and then updates the in-memory index, so deleted data stops influencing
// suggestions immediately. secure_delete is on, and "delete all" also VACUUMs.
import type { Db } from "../store/db.js";
import type { CategoryRepo } from "../store/repos/categories.js";
import type { DecisionRepo } from "../store/repos/decisions.js";
import type { LearningExampleRepo } from "../store/repos/learning-examples.js";
import type { PendingCache } from "../pending/cache.js";
import type { Logger } from "../logging/logger.js";
import { notFound } from "../api/errors.js";
import type { ExampleIndex } from "./index.js";

export interface DeletionDeps {
  db: Db;
  categories: CategoryRepo;
  examples: LearningExampleRepo;
  decisions: DecisionRepo;
  index: ExampleIndex;
  pending: PendingCache;
  logger: Logger;
}

export class DeletionService {
  constructor(private readonly d: DeletionDeps) {}

  deleteExample(userId: string, id: string): void {
    if (!this.d.examples.getOwned(userId, id)) throw notFound("learning example not found");
    // decisions.learning_example_id is set to NULL by the foreign key.
    this.d.db.transaction(() => this.d.examples.deleteById(id))();
    this.d.index.remove(id);
    this.d.logger.info({ learningExampleId: id }, "learning example deleted");
  }

  deleteCategoryExamples(userId: string, categoryId: string): void {
    if (!this.d.categories.getCategory(userId, categoryId)) throw notFound("category not found");
    const n = this.d.db.transaction(() => this.d.examples.deleteByCategory(categoryId))();
    this.d.index.removeByCategory([categoryId]);
    this.d.logger.info({ categoryId, count: n }, "category examples deleted");
  }

  deleteAll(userId: string): void {
    this.d.db.transaction(() => {
      this.d.decisions.deleteAllForUser(userId);
      this.d.examples.deleteAllForUser(userId);
      this.d.db.prepare("DELETE FROM category_sets WHERE user_id = ?").run(userId);
    })();
    this.d.index.clearUser(userId);
    this.d.pending.purgeUser(userId);
    this.d.db.exec("VACUUM");
    this.d.categories.getOrCreateDefaultSet(userId);
    this.d.logger.info({}, "all user data deleted");
  }
}
