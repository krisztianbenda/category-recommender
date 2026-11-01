// Shared Fastify JSON schemas (contracts/http-api.md).

export const emailSchema = {
  type: "object",
  additionalProperties: false,
  required: ["from"],
  properties: {
    from: { type: "string", maxLength: 500 },
    to: { type: "array", maxItems: 100, items: { type: "string", maxLength: 500 } },
    subject: { type: "string", maxLength: 2000, default: "" },
    body: { type: "string", maxLength: 500_000, default: "" },
  },
} as const;

export const categoryPathSchema = { type: "string", minLength: 1, maxLength: 200 } as const;

export const idSchema = { type: "string", pattern: "^[0-9A-HJKMNP-TV-Z]{26}$" } as const;
