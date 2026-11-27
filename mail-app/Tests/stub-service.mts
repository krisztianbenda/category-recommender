// The real service against the stub model, with a throwaway data dir outside the repository, plus
// a tiny server that answers everything with a redirect, to check the client never follows one.
// Also the real service in LAN mode (mutual TLS) with a throwaway PKI, and an impostor HTTPS server
// whose certificate comes from another CA (specs/005-mail-app-lan, research R14).
// Prints one JSON line with the addresses and test files, then runs until killed. Synthetic data
// and test-made certificates only.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";
import { createApp } from "../../service/src/app.js";
import { loadConfig } from "../../service/src/config/load.js";
import { silentLogger } from "../../service/src/logging/logger.js";
import { createTestPki, type ClientCert, type TestPki } from "../../service/tests/helpers/certs.js";
import { keywordChat } from "../../service/tests/helpers/keyword-chat.js";
import { startStubLlm } from "../../service/tests/helpers/stub-llm.js";

const stub = await startStubLlm();
stub.setChat(keywordChat);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-mail-e2e-"));
const configFile = path.join(root, "config.yaml");
fs.writeFileSync(
  configFile,
  // JSON is valid YAML, and the yaml package is not resolvable from here.
  JSON.stringify({
    version: 1,
    server: { bindAddress: "127.0.0.1", port: 8080 },
    storage: { dataDir: path.join(root, "state"), encryption: "external-volume" },
    llm: { baseUrl: stub.url, model: "stub-llm", requestTimeoutSeconds: 5 },
    embeddings: { baseUrl: stub.url, model: "stub-embed" },
  }),
);
const app = await createApp(loadConfig(configFile), { logger: silentLogger, configFile });
await app.server.listen({ host: "127.0.0.1", port: 0 });
const port = (app.server.server.address() as AddressInfo).port;

let targetHits = 0;
const redirector = http.createServer((req, res) => {
  if (req.url === "/target") {
    targetHits += 1;
    res.writeHead(200, { "content-type": "application/json" }).end("[]");
  } else if (req.url === "/hits") {
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ hits: targetHits }));
  } else {
    res.writeHead(302, { location: `http://127.0.0.1:${(redirector.address() as AddressInfo).port}/target` }).end();
  }
});
await new Promise<void>((resolve) => redirector.listen(0, "127.0.0.1", resolve));

// LAN mode: the same service code, with TLS and a device allowlist, on loopback for the test.
const pki: TestPki = createTestPki();
const P12_PASSWORD = "catrec-e2e-only";
const device = pki.issueClient("e2e-mac");
const unlisted = pki.issueClient("e2e-unlisted");
function p12(client: ClientCert): string {
  const base = path.join(pki.dir, client.name);
  fs.writeFileSync(`${base}.pem`, client.cert);
  fs.writeFileSync(`${base}.key`, client.key, { mode: 0o600 });
  // Apple keychains read only the older PKCS#12 algorithms: OpenSSL 3 needs -legacy for them,
  // LibreSSL (macOS's own openssl) uses them already.
  const legacy = execFileSync("openssl", ["version"]).toString().startsWith("OpenSSL 3") ? ["-legacy"] : [];
  execFileSync("openssl", [
    "pkcs12", "-export", ...legacy, "-name", client.name, "-inkey", `${base}.key`, "-in", `${base}.pem`,
    "-certfile", pki.caFile, "-out", `${base}.p12`, "-passout", `pass:${P12_PASSWORD}`,
  ], { stdio: "pipe" });
  return `${base}.p12`;
}
const lanConfigFile = path.join(root, "config-lan.yaml");
fs.writeFileSync(
  lanConfigFile,
  JSON.stringify({
    version: 1,
    server: {
      bindAddress: "127.0.0.1",
      port: 8443,
      tls: { certFile: pki.serverCertFile, keyFile: pki.serverKeyFile, clientCaFile: pki.caFile },
    },
    access: { devices: [{ name: device.name, fingerprintSha256: device.fingerprint, user: "owner" }] },
    storage: { dataDir: path.join(root, "state-lan"), encryption: "external-volume" },
    llm: { baseUrl: stub.url, model: "stub-llm", requestTimeoutSeconds: 5 },
    embeddings: { baseUrl: stub.url, model: "stub-embed" },
  }),
);
const lan = await createApp(loadConfig(lanConfigFile), { logger: silentLogger, configFile: lanConfigFile });
await lan.server.listen({ host: "127.0.0.1", port: 0 });
const lanPort = (lan.server.server.address() as AddressInfo).port;

// The impostor: a valid certificate for 127.0.0.1, but from another CA. It must never get a request.
const other: TestPki = createTestPki();
let impostorHits = 0;
const impostor = https.createServer(
  { key: fs.readFileSync(other.serverKeyFile), cert: fs.readFileSync(other.serverCertFile) },
  (_req, res) => {
    impostorHits += 1;
    res.writeHead(200, { "content-type": "application/json" }).end('{"status":"ok","llm":"up","embeddings":"up"}');
  },
);
await new Promise<void>((resolve) => impostor.listen(0, "127.0.0.1", resolve));
const impostorCounter = http.createServer((_req, res) => {
  res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ hits: impostorHits }));
});
await new Promise<void>((resolve) => impostorCounter.listen(0, "127.0.0.1", resolve));

const portOf = (server: http.Server | https.Server) => (server.address() as AddressInfo).port;
process.stdout.write(
  `${JSON.stringify({
    service: `http://127.0.0.1:${port}`,
    redirector: `http://127.0.0.1:${portOf(redirector)}`,
    lan: `https://127.0.0.1:${lanPort}`,
    caFile: pki.caFile,
    deviceName: device.name,
    deviceP12: p12(device),
    unlistedName: unlisted.name,
    unlistedP12: p12(unlisted),
    p12Password: P12_PASSWORD,
    impostor: `https://127.0.0.1:${portOf(impostor)}`,
    impostorHits: `http://127.0.0.1:${portOf(impostorCounter)}`,
  })}\n`,
);

const stop = async () => {
  await app.close();
  await lan.close();
  await stub.close();
  redirector.close();
  impostor.close();
  impostorCounter.close();
  pki.cleanup();
  other.cleanup();
  fs.rmSync(root, { recursive: true, force: true });
  process.exit(0);
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
