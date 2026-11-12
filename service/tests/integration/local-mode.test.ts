// Local mode (server.tls not set): plain HTTP on loopback for the single owner, no device certs.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { stringify } from "yaml";
import { createApp, type App } from "../../src/app.js";
import { loadConfig } from "../../src/config/load.js";
import { ConfigError, validateConfig } from "../../src/config/schema.js";
import { silentLogger } from "../../src/logging/logger.js";
import { callJson } from "../helpers/http.js";
import { keywordChat } from "../helpers/keyword-chat.js";
import { startStubLlm, type StubLlm } from "../helpers/stub-llm.js";

let stub: StubLlm;
let app: App;
let root: string;
let port: number;

const localConfig = (dataDir: string, server: Record<string, unknown> = {}) => ({
  version: 1,
  server: { bindAddress: "127.0.0.1", port: 8080, ...server },
  storage: { dataDir, encryption: "external-volume" },
  llm: { baseUrl: stub.url, model: "stub-llm", requestTimeoutSeconds: 5 },
  embeddings: { baseUrl: stub.url, model: "stub-embed" },
});

const call = <T = any>(method: string, url: string, body?: unknown, host?: string) =>
  callJson<T>(method, `http://127.0.0.1:${port}${url}`, body, { headers: host ? { host } : {} });

beforeAll(async () => {
  stub = await startStubLlm();
  stub.setChat(keywordChat);
  root = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-local-"));
  const configFile = path.join(root, "config.yaml");
  fs.writeFileSync(configFile, stringify(localConfig(path.join(root, "state"))));
  app = await createApp(loadConfig(configFile), { logger: silentLogger, configFile });
  await app.server.listen({ host: "127.0.0.1", port: 0 });
  port = (app.server.server.address() as AddressInfo).port;
});

afterAll(async () => {
  await app.close();
  await stub.close();
  fs.rmSync(root, { recursive: true, force: true });
});

describe("local mode", () => {
  it("serves suggestions and learns over plain HTTP without a device certificate", async () => {
    expect((await call("GET", "/v1/health")).status).toBe(200);
    const email = {
      from: "dad@example.test",
      subject: "family lunch",
      body: "family lunch sunday",
    };
    const s = await call("POST", "/v1/suggestions", { email, categories: ["Family", "Gadgets"] });
    expect(s.status).toBe(200);
    expect(s.body.category).toBe("Family");
    const fb = await call("POST", `/v1/suggestions/${s.body.suggestionId}/feedback`, {
      email,
      decision: "confirm",
    });
    expect(fb.status).toBe(201);
    expect((await call("GET", "/v1/learning-examples")).body.items).toHaveLength(1);
  });

  it("rejects requests whose Host is not localhost (DNS rebinding)", async () => {
    const r = await call("GET", "/v1/health", undefined, "evil.example.test");
    expect(r.status).toBe(403);
    expect(r.body.error.code).toBe("forbidden");
    expect((await call("GET", "/v1/health", undefined, `localhost:${port}`)).status).toBe(200);
  });

  it("refuses a non-loopback bind address without TLS", () => {
    const raw = localConfig(path.join(root, "x"), { bindAddress: "192.0.2.10" });
    expect(() => validateConfig(raw)).toThrow(ConfigError);
    expect(() => validateConfig(raw)).toThrow(/bindAddress must be 127.0.0.1/);
  });
});
