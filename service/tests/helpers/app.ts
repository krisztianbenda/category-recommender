// Starts the real service against a stub LLM with a temp config + data dir outside the repo.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";
import { Agent, request } from "undici";
import { stringify } from "yaml";
import { createApp, type App } from "../../src/app.js";
import { loadConfig } from "../../src/config/load.js";
import { silentLogger, type Logger } from "../../src/logging/logger.js";
import { createTestPki, type ClientCert, type TestPki } from "./certs.js";
import { startStubLlm, type StubLlm } from "./stub-llm.js";

export interface Response<T = unknown> {
  status: number;
  body: T;
}

export interface TestApp {
  app: App;
  stub: StubLlm;
  pki: TestPki;
  owner: ClientCert;
  baseUrl: string;
  port: number;
  dataDir: string;
  configFile: string;
  rawConfig: Record<string, unknown>;
  agentFor(client: ClientCert): Agent;
  call<T = unknown>(
    method: string,
    url: string,
    body?: unknown,
    client?: ClientCert,
  ): Promise<Response<T>>;
  writeConfig(mutate: (c: Record<string, unknown>) => void): void;
  /** Restarts the service on the same data dir and port (pending suggestions are lost). */
  restart(): Promise<void>;
  close(): Promise<void>;
}

export interface TestAppOptions {
  logger?: Logger;
  stub?: StubLlm;
  learning?: Record<string, unknown>;
  suggestions?: Record<string, unknown>;
}

export async function startTestApp(opts: TestAppOptions = {}): Promise<TestApp> {
  const pki = createTestPki();
  const stub = opts.stub ?? (await startStubLlm());
  const owner = pki.issueClient("owner-laptop");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-app-"));
  const dataDir = path.join(root, "state");
  const configFile = path.join(root, "config.yaml");
  const rawConfig: Record<string, unknown> = {
    version: 1,
    server: {
      bindAddress: "127.0.0.1",
      port: 8443,
      tls: { certFile: pki.serverCertFile, keyFile: pki.serverKeyFile, clientCaFile: pki.caFile },
    },
    access: {
      devices: [{ name: owner.name, fingerprintSha256: owner.fingerprint, user: "owner" }],
    },
    storage: { dataDir, encryption: "external-volume", sqlcipherKeyFile: null },
    llm: { baseUrl: stub.url, model: "stub-llm", maxEmailTokens: 1500, requestTimeoutSeconds: 5 },
    embeddings: { baseUrl: stub.url, model: "stub-embed" },
    learning: {
      neighbours: 8,
      fewShotExamples: 5,
      recencyHalfLifeDays: 180,
      confidence: { knnAgreeShare: 0.6 },
      newCategoryDuplicateSimilarity: 0.9,
      ...opts.learning,
    },
    suggestions: { ttlSeconds: 3600, ...opts.suggestions },
    logging: { level: "info", retentionDays: 14 },
    backup: { ageRecipient: null },
  };
  const writeRaw = () => fs.writeFileSync(configFile, stringify(rawConfig));
  writeRaw();

  let port = 0;
  const start = async () => {
    const config = loadConfig(configFile);
    const app = await createApp(config, {
      logger: opts.logger ?? silentLogger,
      configFile,
      watchIntervalMs: 100,
    });
    await app.server.listen({ host: "127.0.0.1", port });
    port = (app.server.server.address() as AddressInfo).port;
    return app;
  };
  let app = await start();

  const agents = new Map<string, Agent>();
  const agentFor = (client: ClientCert) => {
    let a = agents.get(client.fingerprint);
    if (!a) {
      a = new Agent({
        connect: { ca: pki.ca, cert: client.cert, key: client.key, servername: "localhost" },
      });
      agents.set(client.fingerprint, a);
    }
    return a;
  };

  const t: TestApp = {
    get app() {
      return app;
    },
    stub,
    pki,
    owner,
    get baseUrl() {
      return `https://127.0.0.1:${port}`;
    },
    get port() {
      return port;
    },
    dataDir,
    configFile,
    rawConfig,
    agentFor,
    async call<T>(
      method: string,
      url: string,
      body?: unknown,
      client = owner,
    ): Promise<Response<T>> {
      const res = await request(`https://127.0.0.1:${port}${url}`, {
        method: method as "GET",
        dispatcher: agentFor(client),
        headers: body !== undefined ? { "content-type": "application/json" } : {},
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
      const text = await res.body.text();
      return { status: res.statusCode, body: (text ? JSON.parse(text) : undefined) as T };
    },
    writeConfig(mutate) {
      mutate(rawConfig);
      writeRaw();
    },
    async restart() {
      await app.close();
      for (const a of agents.values()) await a.destroy();
      agents.clear();
      app = await start();
    },
    async close() {
      await app.close();
      for (const a of agents.values()) await a.close();
      if (!opts.stub) await stub.close();
      pki.cleanup();
      fs.rmSync(root, { recursive: true, force: true });
    },
  };
  return t;
}
