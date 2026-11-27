// The server-certificate scripts (specs/005-mail-app-lan, contracts/pki.md), run in a temporary
// directory outside the repository. The keys they make are throwaway test keys.
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const scripts = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../scripts/pki");
let dir: string;

const run = (script: string, args: string[]) =>
  spawnSync(path.join(scripts, script), args, {
    encoding: "utf8",
    env: { ...process.env, CATREC_PKI_DIR: "" },
  });

const certText = (file: string) =>
  execFileSync("openssl", ["x509", "-in", file, "-noout", "-text"], { encoding: "utf8" });

const days = (file: string) => {
  const dates = execFileSync("openssl", ["x509", "-in", file, "-noout", "-startdate", "-enddate"], {
    encoding: "utf8",
  });
  const [start, end] = [...dates.matchAll(/=(.+)$/gm)].map((m) => Date.parse(m[1]!));
  return Math.round((end! - start!) / 86_400_000);
};

beforeAll(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-pki-script-"));
});
afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

describe("server certificate scripts", () => {
  it("init-ca.sh names the address, catrec.local and every --dns name", () => {
    const r = run("init-ca.sh", ["192.168.1.10", "--dns", "test-mini.local", "--dir", dir]);
    expect(r.status, r.stderr).toBe(0);
    const text = certText(path.join(dir, "server.crt"));
    expect(text).toContain("IP Address:192.168.1.10");
    expect(text).toContain("DNS:catrec.local");
    expect(text).toContain("DNS:test-mini.local");
    expect(text).toContain("TLS Web Server Authentication");
    expect(days(path.join(dir, "server.crt"))).toBe(825);
    expect(fs.statSync(path.join(dir, "server.key")).mode & 0o777).toBe(0o600);
    expect(fs.statSync(path.join(dir, "ca.key")).mode & 0o777).toBe(0o600);
  });

  it("new-server-cert.sh replaces the server certificate, keeps the old one, and leaves the CA", () => {
    const ca = fs.readFileSync(path.join(dir, "ca.crt"));
    const old = fs.readFileSync(path.join(dir, "server.crt"));
    const r = run("new-server-cert.sh", ["192.168.1.11", "--dir", dir]);
    expect(r.status, r.stderr).toBe(0);
    const text = certText(path.join(dir, "server.crt"));
    expect(text).toContain("IP Address:192.168.1.11");
    expect(text).not.toContain("test-mini.local");
    expect(fs.readFileSync(path.join(dir, "server.crt.previous"))).toEqual(old);
    expect(fs.existsSync(path.join(dir, "server.key.previous"))).toBe(true);
    expect(fs.readFileSync(path.join(dir, "ca.crt"))).toEqual(ca);
    execFileSync("openssl", [
      "verify",
      "-CAfile",
      path.join(dir, "ca.crt"),
      path.join(dir, "server.crt"),
    ]);
  });

  it("refuses without a CA, a bad name or a bad address", () => {
    const empty = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-pki-empty-"));
    try {
      expect(run("new-server-cert.sh", ["192.168.1.11", "--dir", empty]).status).not.toBe(0);
    } finally {
      fs.rmSync(empty, { recursive: true, force: true });
    }
    expect(
      run("new-server-cert.sh", ["192.168.1.11", "--dns", "bad name", "--dir", dir]).status,
    ).toBe(2);
    expect(run("new-server-cert.sh", ["mini.local", "--dir", dir]).status).toBe(2);
    expect(run("init-ca.sh", ["192.168.1.10", "--dir", dir]).status).not.toBe(0);
  });
});
