import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";
import { idParams, idSchema } from "../schemas.js";

export function learningDataRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get<{ Querystring: { categoryId?: string; limit: number; cursor?: string } }>(
    "/v1/learning-examples",
    {
      schema: {
        querystring: {
          type: "object",
          additionalProperties: false,
          properties: {
            categoryId: idSchema,
            limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
            cursor: idSchema,
          },
        },
      },
    },
    async (request) => {
      const { items, nextCursor } = ctx.examples.listPaged(request.userId, request.query);
      // Resolve current paths (they follow renames/moves) per set.
      const paths = new Map<string, Map<string, string>>();
      const pathOf = (setId: string, categoryId: string | null) => {
        if (categoryId === null) return null; // the owner deleted the email
        let m = paths.get(setId);
        if (!m)
          paths.set(
            setId,
            (m = new Map(ctx.categories.listCategories(setId).map((c) => [c.id, c.path]))),
          );
        return m.get(categoryId) ?? "";
      };
      return {
        items: items.map((e) => ({
          id: e.id,
          categoryPath: pathOf(e.setId, e.categoryId),
          sender: e.sender,
          subject: e.subject,
          snippet: e.snippet,
          outcome: e.outcome,
          decidedAt: e.decidedAt,
        })),
        nextCursor,
      };
    },
  );

  app.delete<{ Params: { id: string } }>(
    "/v1/learning-examples/:id",
    { schema: { params: idParams } },
    async (request, reply) => {
      ctx.deletion.deleteExample(request.userId, request.params.id);
      return reply.code(204).send();
    },
  );

  app.delete<{ Params: { id: string } }>(
    "/v1/categories/:id/learning-examples",
    { schema: { params: idParams } },
    async (request, reply) => {
      ctx.deletion.deleteCategoryExamples(request.userId, request.params.id);
      return reply.code(204).send();
    },
  );

  app.delete<{ Body: { confirm: string } }>(
    "/v1/me/data",
    {
      schema: {
        body: {
          type: "object",
          required: ["confirm"],
          properties: { confirm: { const: "DELETE ALL" } },
        },
      },
    },
    async (request, reply) => {
      ctx.deletion.deleteAll(request.userId);
      return reply.code(204).send();
    },
  );
}
