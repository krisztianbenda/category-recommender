import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";
import { idParams, idSchema } from "../schemas.js";

export function categoryRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.patch<{ Params: { id: string }; Body: { name?: string; parentId?: string | null } }>(
    "/v1/categories/:id",
    {
      schema: {
        params: idParams,
        body: {
          type: "object",
          additionalProperties: false,
          minProperties: 1,
          properties: {
            name: { type: "string", minLength: 1, maxLength: 200 },
            parentId: { anyOf: [idSchema, { type: "null" }] },
          },
        },
      },
    },
    async (request) => {
      await ctx.categoryService.updateCategory(request.userId, request.params.id, request.body);
      const c = ctx.categories.getCategory(request.userId, request.params.id)!;
      return { id: c.id, path: c.path, parentId: c.parentId };
    },
  );

  app.delete<{ Params: { id: string }; Querystring: { cascade: boolean } }>(
    "/v1/categories/:id",
    {
      schema: {
        params: idParams,
        querystring: {
          type: "object",
          properties: { cascade: { type: "boolean", default: false } },
        },
      },
    },
    async (request, reply) => {
      ctx.categoryService.deleteCategory(request.userId, request.params.id, request.query.cascade);
      return reply.code(204).send();
    },
  );
}
