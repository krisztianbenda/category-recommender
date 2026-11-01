import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";
import { accuracy } from "../../learning/stats.js";

export function statsRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get<{ Querystring: { window: number } }>(
    "/v1/stats/accuracy",
    {
      schema: {
        querystring: {
          type: "object",
          properties: { window: { type: "integer", enum: [50, 100], default: 100 } },
        },
      },
    },
    async (request) => accuracy(ctx.decisions, request.userId, request.query.window),
  );
}
