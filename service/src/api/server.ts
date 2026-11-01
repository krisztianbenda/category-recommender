import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Fastify, { type FastifyError, type FastifyInstance } from "fastify";
import type { AppContext } from "../context.js";
import { registerAccessControl } from "../security/access.js";
import { registerLocalAccess } from "../security/local.js";
import { PathError } from "../categories/path.js";
import { LlmOutputError, LlmUnavailableError, NonLocalEndpointError } from "../llm/client.js";
import { AppError, envelope } from "./errors.js";

export type RouteModule = (app: FastifyInstance, ctx: AppContext) => void;

const WEB_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../web");
const STATIC_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};

function registerStatic(app: FastifyInstance, webDir: string): void {
  const files = fs.existsSync(webDir) ? fs.readdirSync(webDir) : [];
  for (const file of files) {
    const type = STATIC_TYPES[path.extname(file)];
    if (!type) continue;
    const full = path.join(webDir, file);
    const url = file === "index.html" ? "/" : `/${file}`;
    app.get(url, async (_req, reply) =>
      reply
        .header("content-type", type)
        .header("cache-control", "no-store")
        .header("content-security-policy", "default-src 'self'; frame-ancestors 'none'")
        .header("x-content-type-options", "nosniff")
        .send(fs.createReadStream(full)),
    );
  }
}

export function buildServer(
  ctx: AppContext,
  routes: RouteModule[],
  webDir = WEB_DIR,
): FastifyInstance {
  const { tls } = ctx.config.server;
  const base = { logger: false, bodyLimit: 1024 * 1024 }; // our own redacting logger only
  let app: FastifyInstance;
  if (tls) {
    app = Fastify({
      ...base,
      https: {
        key: fs.readFileSync(tls.keyFile),
        cert: fs.readFileSync(tls.certFile),
        ca: fs.readFileSync(tls.clientCaFile),
        requestCert: true,
        rejectUnauthorized: true,
        minVersion: "TLSv1.2",
      },
    });
    registerAccessControl(app, ctx.access);
  } else {
    app = Fastify(base);
    registerLocalAccess(app);
  }

  app.addHook("onResponse", async (request, reply) => {
    ctx.logger.info(
      {
        reqId: request.id,
        route: request.routeOptions.url ?? "unmatched",
        method: request.method,
        status: reply.statusCode,
        durationMs: Math.round(reply.elapsedTime),
      },
      "request",
    );
  });

  app.setErrorHandler((err: FastifyError | Error, request, reply) => {
    if (err instanceof AppError) {
      return reply.code(err.status).send(envelope(err.code, err.message));
    }
    if (err instanceof PathError) {
      return reply.code(400).send(envelope("invalid_request", err.message));
    }
    if (err instanceof LlmUnavailableError || err instanceof NonLocalEndpointError) {
      ctx.logger.warn(
        { reqId: request.id, errorCode: "llm_unavailable" },
        "model runtime unavailable",
      );
      return reply
        .code(503)
        .send(envelope("llm_unavailable", "the local model is unavailable, try again later"));
    }
    if (err instanceof LlmOutputError) {
      ctx.logger.warn(
        { reqId: request.id, errorCode: "llm_output_invalid" },
        "unusable model answer",
      );
      return reply
        .code(503)
        .send(envelope("llm_unavailable", "the local model gave an unusable answer, try again"));
    }
    const fe = err as FastifyError;
    if (fe.validation) {
      const where = fe.validation[0]?.instancePath || fe.validationContext || "request";
      return reply.code(400).send(envelope("invalid_request", `invalid value at ${where}`));
    }
    if (typeof fe.statusCode === "number" && fe.statusCode >= 400 && fe.statusCode < 500) {
      return reply.code(fe.statusCode).send(envelope("invalid_request", "malformed request"));
    }
    ctx.logger.error({ reqId: request.id, errorCode: "internal" }, "unhandled error");
    return reply.code(500).send(envelope("internal", "internal error"));
  });

  app.setNotFoundHandler((_req, reply) => reply.code(404).send(envelope("not_found", "not found")));

  registerStatic(app, webDir);
  for (const route of routes) route(app, ctx);
  return app;
}
