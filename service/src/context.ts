import type { Config } from "./config/schema.js";
import type { AccessList } from "./config/watch.js";
import type { Logger } from "./logging/logger.js";
import type { Db } from "./store/db.js";
import type { CategoryRepo } from "./store/repos/categories.js";
import type { Embedder, LlmClient } from "./llm/client.js";
import type { SerialQueue } from "./llm/queue.js";
import type { PendingCache } from "./pending/cache.js";
import type { SuggestionPipeline } from "./suggest/pipeline.js";
import type { LearningExampleRepo } from "./store/repos/learning-examples.js";
import type { DecisionRepo } from "./store/repos/decisions.js";
import type { ExampleIndex } from "./learning/index.js";
import type { FeedbackService } from "./learning/feedback.js";
import type { CategoryService } from "./categories/service.js";
import type { DeletionService } from "./learning/deletion.js";

/** Everything route handlers and services need, built once in app.ts. */
export interface AppContext {
  config: Config;
  access: AccessList;
  logger: Logger;
  db: Db;
  categories: CategoryRepo;
  llm: LlmClient;
  embedder: Embedder & { health(): Promise<boolean> };
  queue: SerialQueue;
  pending: PendingCache;
  pipeline: SuggestionPipeline;
  examples: LearningExampleRepo;
  decisions: DecisionRepo;
  index: ExampleIndex;
  feedback: FeedbackService;
  categoryService: CategoryService;
  deletion: DeletionService;
}
