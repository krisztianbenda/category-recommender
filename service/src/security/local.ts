// Local mode (server.tls: null): plain HTTP on a loopback address for the single owner. Only the
// loopback Host names are accepted, so a web page cannot reach the API through DNS rebinding.
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { LOCAL_USER } from "../config/schema.js";
import { envelope } from "../api/errors.js";

const LOCAL_HOSTS = ["127.0.0.1", "localhost", "[::1]"];

export function isLocalHost(host: string | undefined, port: number | undefined): boolean {
  return LOCAL_HOSTS.some((h) => (host ?? "").toLowerCase() === `${h}:${port}`);
}

export function registerLocalAccess(app: FastifyInstance): void {
  app.decorateRequest("userId", "");
  app.decorateRequest("deviceName", "");
  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    if (!isLocalHost(request.headers.host, request.raw.socket.localPort)) {
      return reply.code(403).send(envelope("forbidden", "only localhost is allowed"));
    }
    request.userId = LOCAL_USER;
    request.deviceName = "local";
  });
}
