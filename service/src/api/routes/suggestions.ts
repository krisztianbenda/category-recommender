import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";
import type { Email, TrashedEmail } from "../../suggest/types.js";
import { invalid } from "../errors.js";
import { categoryPathSchema, emailSchema, idSchema } from "../schemas.js";

interface SuggestBody {
  email: Email;
  categories?: string[];
  categorySetId?: string;
  allowDelete: boolean;
  trash?: TrashedEmail[];
}

export function suggestionRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post<{ Body: SuggestBody }>(
    "/v1/suggestions",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["email"],
          properties: {
            email: emailSchema,
            categories: { type: "array", maxItems: 200, items: categoryPathSchema },
            categorySetId: idSchema,
            allowDelete: { type: "boolean", default: false },
            trash: {
              type: "array",
              maxItems: 50,
              items: {
                type: "object",
                additionalProperties: false,
                required: ["from"],
                properties: {
                  from: { type: "string", maxLength: 500 },
                  subject: { type: "string", maxLength: 2000, default: "" },
                },
              },
            },
          },
        },
      },
    },
    async (request) => {
      const { email, categories, categorySetId, allowDelete, trash } = request.body;
      if ((categories === undefined) === (categorySetId === undefined)) {
        throw invalid("give exactly one of categories or categorySetId");
      }
      return ctx.pipeline.suggest(request.userId, {
        email,
        categories,
        categorySetId,
        allowDelete,
        trash,
      });
    },
  );
}
