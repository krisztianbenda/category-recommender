import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";

export function healthRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get("/v1/health", async () => {
    const [llm, embeddings] = await Promise.all([ctx.llm.health(), ctx.embedder.health()]);
    return {
      status: llm && embeddings ? "ok" : "degraded",
      llm: llm ? "up" : "down",
      embeddings: embeddings ? "up" : "down",
    };
  });
}
