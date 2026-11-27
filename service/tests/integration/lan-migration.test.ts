// Moving from local mode to the LAN install (specs/005-mail-app-lan, FR-021, SC-005): what was
// learned in local mode, backed up and restored for a LAN-mode service, belongs to the same owner
// there, and recommends the same. Synthetic emails, a test-made PKI, and a pass-through stand-in for
// `age` (as in backup.test.ts); nothing real.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";
import { Agent } from "undici";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { stringify } from "yaml";
import { createApp, type App } from "../../src/app.js";
import { backup } from "../../src/cli/backup.js";
import { restore } from "../../src/cli/restore.js";
import { loadConfig } from "../../src/config/load.js";
import { silentLogger } from "../../src/logging/logger.js";
import { createTestPki, type TestPki } from "../helpers/certs.js";
import { callJson } from "../helpers/http.js";
import { keywordChat } from "../helpers/keyword-chat.js";
import { startStubLlm, type StubLlm } from "../helpers/stub-llm.js";

let stub: StubLlm;
let pki: TestPki;
let root: string;
const apps: App[] = [];

const emails = [
  { from: "dad@example.test", subject: "family lunch", body: "family lunch on sunday" },
  {
    from: "shop@example.test",
    subject: "new gadgets",
    body: "the gadgets you ordered have shipped",
  },
  {
    from: "clinic@example.test",
    subject: "family check-up",
    body: "the family check-up is on friday",
  },
];

beforeAll(async () => {
  stub = await startStubLlm();
  stub.setChat(keywordChat);
  pki = createTestPki();
  root = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-migrate-"));
  const fakeAge = path.join(root, "fake-age.sh");
  fs.writeFileSync(
    fakeAge,
    '#!/bin/sh\nout=""; while [ $# -gt 1 ]; do case "$1" in -o) out="$2"; shift 2;; -r|-i) shift 2;; *) shift;; esac; done; cp "$1" "$out"\n',
    { mode: 0o755 },
  );
  process.env.CATREC_AGE_BIN = fakeAge;
});

afterAll(async () => {
  delete process.env.CATREC_AGE_BIN;
  for (const app of apps) await app.close();
  await stub.close();
  pki.cleanup();
  fs.rmSync(root, { recursive: true, force: true });
});

async function start(configFile: string): Promise<number> {
  const app = await createApp(loadConfig(configFile), { logger: silentLogger, configFile });
  await app.server.listen({ host: "127.0.0.1", port: 0 });
  apps.push(app);
  return (app.server.server.address() as AddressInfo).port;
}

describe("moving learning from local mode to LAN mode", () => {
  it("keeps every category and example, and the same recommendations, for the owner's devices", async () => {
    // Local mode, as on the Mac mini today.
    const localConfig = path.join(root, "local.yaml");
    fs.writeFileSync(
      localConfig,
      stringify({
        version: 1,
        server: { bindAddress: "127.0.0.1", port: 8080 },
        storage: { dataDir: path.join(root, "local-state"), encryption: "external-volume" },
        llm: { baseUrl: stub.url, model: "stub-llm", requestTimeoutSeconds: 5 },
        embeddings: { baseUrl: stub.url, model: "stub-embed" },
        backup: { ageRecipient: "age1placeholder" },
      }),
    );
    const localPort = await start(localConfig);
    const local = <T = any>(method: string, url: string, body?: unknown) =>
      callJson<T>(method, `http://127.0.0.1:${localPort}${url}`, body);

    const set = (
      await local<{ id: string }>("POST", "/v1/category-sets", {
        name: "Gmail: owner@example.test",
        categories: ["Family", "Gadgets", "Finance"],
      })
    ).body;
    const before: string[] = [];
    for (const email of emails) {
      const s = (await local<any>("POST", "/v1/suggestions", { email, categorySetId: set.id }))
        .body;
      before.push(s.category);
      const fb = await local("POST", `/v1/suggestions/${s.suggestionId}/feedback`, {
        email,
        decision: "confirm",
      });
      expect(fb.status).toBeLessThan(300);
    }
    const localSet = (await local<any>("GET", `/v1/category-sets/${set.id}`)).body;

    // Backup in local mode, restore into the LAN install's data directory.
    const out = path.join(root, "backup.age");
    await backup(loadConfig(localConfig), localConfig, out);
    const lanDir = path.join(root, "lan-state");
    const device = pki.issueClient("owner-macbook");
    const lanConfig = path.join(root, "lan.yaml");
    fs.writeFileSync(
      lanConfig,
      stringify({
        version: 1,
        server: {
          bindAddress: "127.0.0.1",
          port: 8443,
          tls: {
            certFile: pki.serverCertFile,
            keyFile: pki.serverKeyFile,
            clientCaFile: pki.caFile,
          },
        },
        access: {
          devices: [{ name: device.name, fingerprintSha256: device.fingerprint, user: "owner" }],
        },
        storage: { dataDir: lanDir, encryption: "external-volume" },
        llm: { baseUrl: stub.url, model: "stub-llm", requestTimeoutSeconds: 5 },
        embeddings: { baseUrl: stub.url, model: "stub-embed" },
      }),
    );
    restore(loadConfig(lanConfig), out, path.join(root, "identity.txt"));

    // LAN mode, reached with the owner's device certificate.
    const lanPort = await start(lanConfig);
    const agent = new Agent({
      connect: { ca: pki.ca, cert: device.cert, key: device.key, servername: "localhost" },
    });
    const lan = <T = any>(method: string, url: string, body?: unknown) =>
      callJson<T>(method, `https://127.0.0.1:${lanPort}${url}`, body, { dispatcher: agent });

    const sets = (await lan<{ id: string; name: string }[]>("GET", "/v1/category-sets")).body;
    expect(sets.map((s) => s.name)).toContain("Gmail: owner@example.test");
    const lanSet = (await lan<any>("GET", `/v1/category-sets/${set.id}`)).body;
    expect(lanSet.categories).toEqual(localSet.categories);
    expect(lanSet.categories.reduce((n: number, c: any) => n + c.exampleCount, 0)).toBe(3);

    const after: string[] = [];
    for (const email of emails) {
      after.push(
        (await lan<any>("POST", "/v1/suggestions", { email, categorySetId: set.id })).body.category,
      );
    }
    expect(after).toEqual(before);
    await agent.close();
  });
});
