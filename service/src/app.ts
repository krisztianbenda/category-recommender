import type { FastifyInstance } from "fastify";
import type { Config } from "./config/schema.js";
import { AccessList, watchAccessList, type WatchHandle } from "./config/watch.js";
import type { AppContext } from "./context.js";
import { EmbeddingsClient, LlmClient } from "./llm/client.js";
import { SerialQueue } from "./llm/queue.js";
import type { Logger } from "./logging/logger.js";
import { buildServer, type RouteModule } from "./api/server.js";
import { healthRoutes } from "./api/routes/health.js";
import { suggestionRoutes } from "./api/routes/suggestions.js";
import { PendingCache } from "./pending/cache.js";
import { SuggestionPipeline } from "./suggest/pipeline.js";
import { feedbackRoutes } from "./api/routes/feedback.js";
import { statsRoutes } from "./api/routes/stats.js";
import { ExampleIndex, reembedStale, toEntry } from "./learning/index.js";
import { KnnRetriever } from "./learning/knn.js";
import { FeedbackService } from "./learning/feedback.js";
import { LearningExampleRepo } from "./store/repos/learning-examples.js";
import { DecisionRepo } from "./store/repos/decisions.js";
import { CategoryService } from "./categories/service.js";
import { DeletionService } from "./learning/deletion.js";
import { categorySetRoutes } from "./api/routes/category-sets.js";
import { categoryRoutes } from "./api/routes/categories.js";
import { learningDataRoutes } from "./api/routes/learning-data.js";
import { dbFileFor, migrate, openDb } from "./store/db.js";
import { CategoryRepo } from "./store/repos/categories.js";

export interface AppOptions {
  logger: Logger;
  /** Config file to watch for access.devices changes (hot reload). */
  configFile?: string;
  watchIntervalMs?: number;
}

export interface App {
  ctx: AppContext;
  server: FastifyInstance;
  listen(): Promise<string>;
  close(): Promise<void>;
}

export const routeModules: RouteModule[] = [
  healthRoutes,
  suggestionRoutes,
  feedbackRoutes,
  statsRoutes,
  categorySetRoutes,
  categoryRoutes,
  learningDataRoutes,
];

export function createContext(config: Config, logger: Logger): AppContext {
  const db = openDb(dbFileFor(config.storage.dataDir));
  migrate(db);
  const categories = new CategoryRepo(db);
  const users = new Set(config.access.devices.map((d) => d.user));
  for (const user of users) {
    categories.ensureUser(user);
    categories.getOrCreateDefaultSet(user);
  }
  const timeoutMs = config.llm.requestTimeoutSeconds * 1000;
  const llm = new LlmClient({ baseUrl: config.llm.baseUrl, model: config.llm.model, timeoutMs });
  const embedder = new EmbeddingsClient({
    baseUrl: config.embeddings.baseUrl,
    model: config.embeddings.model,
    timeoutMs,
  });
  const queue = new SerialQueue();
  const pending = new PendingCache(config.suggestions.ttlSeconds * 1000);
  const examples = new LearningExampleRepo(db);
  const decisions = new DecisionRepo(db);
  const index = new ExampleIndex();
  index.load(examples.listAll().map(toEntry));
  const retriever = new KnnRetriever(
    index,
    (setId) =>
      new Map(categories.listCategories(setId).map((c) => [c.id, { key: c.key, path: c.path }])),
    { ...config.learning, embeddingModel: () => embedder.model },
  );
  const pipeline = new SuggestionPipeline({
    config,
    categories,
    llm,
    embedder,
    queue,
    pending,
    logger,
    retriever,
  });
  const feedback = new FeedbackService({
    db,
    categories,
    examples,
    decisions,
    index,
    pending,
    embedder,
    logger,
  });
  const categoryService = new CategoryService({ categories, embedder, index, logger });
  const deletion = new DeletionService({
    db,
    categories,
    examples,
    decisions,
    index,
    pending,
    logger,
  });
  return {
    config,
    access: new AccessList(config.access.devices),
    logger,
    db,
    categories,
    llm,
    embedder,
    queue,
    pending,
    pipeline,
    examples,
    decisions,
    index,
    feedback,
    categoryService,
    deletion,
  };
}

export async function createApp(config: Config, opts: AppOptions): Promise<App> {
  const ctx = createContext(config, opts.logger);
  await reembedStale(ctx.examples, ctx.index, ctx.embedder, ctx.logger);
  const server = buildServer(ctx, routeModules);
  ctx.pending.start();
  let watcher: WatchHandle | undefined;
  if (opts.configFile) {
    watcher = watchAccessList(
      opts.configFile,
      ctx.access,
      (errorCode) => ctx.logger.error({ errorCode }, "access allowlist not reloaded"),
      opts.watchIntervalMs,
    );
  }
  return {
    ctx,
    server,
    listen: () => server.listen({ host: config.server.bindAddress, port: config.server.port }),
    close: async () => {
      watcher?.close();
      ctx.pending.stop();
      await server.close();
      ctx.db.close();
    },
  };
}
