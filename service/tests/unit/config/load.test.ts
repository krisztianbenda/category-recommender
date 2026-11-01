import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { parse, stringify } from "yaml";
import { findRepoRoot, isLoopbackUrl, loadConfig } from "../../../src/config/load.js";
import { ConfigError } from "../../../src/config/schema.js";

const repoRoot = findRepoRoot(path.dirname(fileURLToPath(import.meta.url)))!;
const example = parse(fs.readFileSync(path.join(repoRoot, "deploy/config.example.yaml"), "utf8"));

let tmp: string;
let keyFile: string;

function write(mutate: (c: any) => void): string {
  const c = structuredClone(example);
  c.server.tls.keyFile = keyFile;
  c.storage.dataDir = path.join(tmp, "state");
  mutate(c);
  const f = path.join(tmp, `config-${Math.random().toString(36).slice(2)}.yaml`);
  fs.writeFileSync(f, stringify(c));
  return f;
}

function problems(file: string): string[] {
  try {
    loadConfig(file, { repoRoots: [repoRoot] });
    return [];
  } catch (e) {
    if (e instanceof ConfigError) return e.problems;
    throw e;
  }
}

beforeAll(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-cfg-"));
  keyFile = path.join(tmp, "server.key");
  fs.writeFileSync(keyFile, "placeholder", { mode: 0o600 });
});

afterAll(() => fs.rmSync(tmp, { recursive: true, force: true }));

describe("config loading", () => {
  it("accepts the committed example (with a private key file and a temp data dir)", () => {
    expect(problems(write(() => {}))).toEqual([]);
  });

  it("rejects a data dir inside the repository", () => {
    const p = problems(write((c) => (c.storage.dataDir = path.join(repoRoot, "some-state"))));
    expect(p).toContain("storage.dataDir must be outside the repository working tree");
  });

  it("rejects non-loopback model endpoints", () => {
    const p = problems(
      write((c) => {
        c.llm.baseUrl = "https://api.example.com/v1";
        c.embeddings.baseUrl = "http://192.168.1.20:8082/v1";
      }),
    );
    expect(p).toContain("llm.baseUrl must be a loopback address");
    expect(p).toContain("embeddings.baseUrl must be a loopback address");
  });

  it("rejects a world-readable key file", () => {
    const loose = path.join(tmp, "loose.key");
    fs.writeFileSync(loose, "placeholder");
    fs.chmodSync(loose, 0o644);
    const p = problems(write((c) => (c.server.tls.keyFile = loose)));
    expect(p).toContain("server.tls.keyFile must not be world-readable (chmod 600)");
  });

  it("rejects sqlcipher without a key file and malformed fingerprints", () => {
    const p = problems(
      write((c) => {
        c.storage.encryption = "sqlcipher";
        c.access.devices[0].fingerprintSha256 = "not-a-fingerprint";
      }),
    );
    expect(p).toContain(
      "storage.sqlcipherKeyFile is required when storage.encryption is sqlcipher",
    );
    expect(p.some((x) => x.includes("fingerprintSha256"))).toBe(true);
  });

  it("recognises loopback URLs only", () => {
    expect(isLoopbackUrl("http://127.0.0.1:8081/v1")).toBe(true);
    expect(isLoopbackUrl("http://localhost:8081/v1")).toBe(true);
    expect(isLoopbackUrl("http://[::1]:8081/v1")).toBe(true);
    expect(isLoopbackUrl("http://127.0.0.1.example.com/v1")).toBe(false);
    expect(isLoopbackUrl("http://10.0.0.5/v1")).toBe(false);
  });
});
