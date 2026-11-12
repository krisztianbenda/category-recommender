import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";
import { categoryPathSchema, idParams } from "../schemas.js";

const nameSchema = { type: "string", minLength: 1, maxLength: 80 } as const;

export function categorySetRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get("/v1/category-sets", async (request) => ctx.categoryService.listSets(request.userId));

  app.post<{ Body: { name: string; categories?: string[] } }>(
    "/v1/category-sets",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["name"],
          properties: {
            name: nameSchema,
            categories: { type: "array", maxItems: 500, items: categoryPathSchema },
          },
        },
      },
    },
    async (request, reply) => {
      const id = await ctx.categoryService.createSet(
        request.userId,
        request.body.name,
        request.body.categories,
      );
      return reply.code(201).send({ id });
    },
  );

  app.get<{ Params: { id: string } }>(
    "/v1/category-sets/:id",
    { schema: { params: idParams } },
    async (request) => ctx.categoryService.getSet(request.userId, request.params.id),
  );

  app.patch<{ Params: { id: string }; Body: { name: string } }>(
    "/v1/category-sets/:id",
    {
      schema: {
        params: idParams,
        body: {
          type: "object",
          additionalProperties: false,
          required: ["name"],
          properties: { name: nameSchema },
        },
      },
    },
    async (request) => {
      ctx.categoryService.renameSet(request.userId, request.params.id, request.body.name);
      return ctx.categoryService.getSet(request.userId, request.params.id);
    },
  );

  app.delete<{ Params: { id: string } }>(
    "/v1/category-sets/:id",
    { schema: { params: idParams } },
    async (request, reply) => {
      ctx.categoryService.deleteSet(request.userId, request.params.id);
      return reply.code(204).send();
    },
  );

  app.post<{ Params: { id: string }; Body: { path: string } }>(
    "/v1/category-sets/:id/categories",
    {
      schema: {
        params: idParams,
        body: {
          type: "object",
          additionalProperties: false,
          required: ["path"],
          properties: { path: categoryPathSchema },
        },
      },
    },
    async (request, reply) => {
      const id = await ctx.categoryService.addCategory(
        request.userId,
        request.params.id,
        request.body.path,
      );
      return reply.code(201).send({ id });
    },
  );
}
