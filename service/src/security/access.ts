// mTLS device allowlist (research R13, FR-015). The TLS layer already rejects clients without a
// certificate from our CA; this hook additionally requires the certificate's fingerprint to be in
// the live allowlist and maps the device to its user.
import type { TLSSocket } from "node:tls";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { AccessList } from "../config/watch.js";
import { envelope } from "../api/errors.js";

declare module "fastify" {
  interface FastifyRequest {
    userId: string;
    deviceName: string;
  }
}

export function peerFingerprint(request: FastifyRequest): string | null {
  const socket = request.raw.socket as TLSSocket;
  if (typeof socket.getPeerCertificate !== "function") return null;
  const cert = socket.getPeerCertificate();
  return cert && cert.fingerprint256 ? cert.fingerprint256.toUpperCase() : null;
}

export function registerAccessControl(app: FastifyInstance, access: AccessList): void {
  app.decorateRequest("userId", "");
  app.decorateRequest("deviceName", "");
  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    const fp = peerFingerprint(request);
    const device = fp ? access.lookup(fp) : undefined;
    if (!device) {
      return reply.code(403).send(envelope("forbidden", "this device is not allowed"));
    }
    request.userId = device.user;
    request.deviceName = device.name;
  });
}
