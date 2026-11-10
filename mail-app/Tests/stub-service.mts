// The real service against the stub model, with a throwaway data dir outside the repository, plus
// a tiny server that answers everything with a redirect, to check the client never follows one.
// Prints one JSON line with the addresses, then runs until killed. Synthetic data only.
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";
import { createApp } from "../../service/src/app.js";
import { loadConfig } from "../../service/src/config/load.js";
import { silentLogger } from "../../service/src/logging/logger.js";
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

process.stdout.write(
  `${JSON.stringify({ service: `http://127.0.0.1:${port}`, redirector: `http://127.0.0.1:${(redirector.address() as AddressInfo).port}` })}\n`,
);

const stop = async () => {
  await app.close();
  await stub.close();
  redirector.close();
  fs.rmSync(root, { recursive: true, force: true });
  process.exit(0);
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
