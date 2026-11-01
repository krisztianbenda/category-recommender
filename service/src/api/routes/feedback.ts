import type { FastifyInstance } from "fastify";
import type { AppContext } from "../../context.js";
import type { FeedbackInput } from "../../learning/feedback.js";
import { categoryPathSchema, emailSchema, idSchema } from "../schemas.js";

export function feedbackRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post<{ Params: { id: string }; Body: FeedbackInput }>(
    "/v1/suggestions/:id/feedback",
    {
      schema: {
        params: { type: "object", required: ["id"], properties: { id: idSchema } },
        body: {
          type: "object",
          additionalProperties: false,
          required: ["email", "decision"],
          properties: {
            email: emailSchema,
            decision: { enum: ["confirm", "choose", "accept_new"] },
            category: categoryPathSchema,
            newCategory: {
              type: "object",
              additionalProperties: false,
              required: ["parent", "name"],
              properties: {
                parent: {
                  anyOf: [{ type: "string", minLength: 1, maxLength: 60 }, { type: "null" }],
                },
                name: { type: "string", minLength: 1, maxLength: 60 },
              },
            },
          },
          allOf: [
            {
              if: { properties: { decision: { const: "choose" } } },
              then: { required: ["category"] },
            },
            {
              if: { properties: { decision: { const: "accept_new" } } },
              then: { required: ["newCategory"] },
            },
          ],
        },
      },
    },
    async (request, reply) => {
      const result = await ctx.feedback.record(request.userId, request.params.id, request.body);
      return reply.code(201).send(result);
    },
  );
}
