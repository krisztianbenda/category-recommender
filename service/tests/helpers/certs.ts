// Throwaway test PKI in a temp dir outside the repo (never committed, never real).
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface ClientCert {
  name: string;
  cert: Buffer;
  key: Buffer;
  fingerprint: string;
}

export interface TestPki {
  dir: string;
  caFile: string;
  serverCertFile: string;
  serverKeyFile: string;
  ca: Buffer;
  issueClient(name: string, opts?: { selfSigned?: boolean }): ClientCert;
  cleanup(): void;
}

function ssl(dir: string, args: string[]): void {
  execFileSync("openssl", args, { cwd: dir, stdio: "pipe" });
}

function ecKey(dir: string, file: string): void {
  ssl(dir, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", file]);
  fs.chmodSync(path.join(dir, file), 0o600);
}

function signed(
  dir: string,
  base: string,
  subject: string,
  ext: string,
  caBase: string | null,
): void {
  ecKey(dir, `${base}.key`);
  ssl(dir, ["req", "-new", "-key", `${base}.key`, "-out", `${base}.csr`, "-subj", subject]);
  fs.writeFileSync(path.join(dir, `${base}.ext`), ext);
  const signArgs = caBase
    ? ["-CA", `${caBase}.crt`, "-CAkey", `${caBase}.key`, "-CAcreateserial"]
    : ["-signkey", `${base}.key`];
  ssl(dir, [
    "x509",
    "-req",
    "-in",
    `${base}.csr`,
    ...signArgs,
    "-out",
    `${base}.crt`,
    "-days",
    "2",
    "-sha256",
    "-extfile",
    `${base}.ext`,
  ]);
}

export function fingerprintOf(certPem: Buffer | string): string {
  return new crypto.X509Certificate(certPem).fingerprint256.toUpperCase();
}

export function createTestPki(): TestPki {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-pki-"));
  signed(
    dir,
    "ca",
    "/CN=catrec-test-ca",
    "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n",
    null,
  );
  signed(
    dir,
    "server",
    "/CN=localhost",
    "basicConstraints=CA:FALSE\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n",
    "ca",
  );
  let n = 0;
  return {
    dir,
    caFile: path.join(dir, "ca.crt"),
    serverCertFile: path.join(dir, "server.crt"),
    serverKeyFile: path.join(dir, "server.key"),
    ca: fs.readFileSync(path.join(dir, "ca.crt")),
    issueClient(name, opts = {}) {
      const base = `client${n++}`;
      const ext = "basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n";
      signed(dir, base, `/CN=${name}`, ext, opts.selfSigned ? null : "ca");
      const cert = fs.readFileSync(path.join(dir, `${base}.crt`));
      return {
        name,
        cert,
        key: fs.readFileSync(path.join(dir, `${base}.key`)),
        fingerprint: fingerprintOf(cert),
      };
    },
    cleanup() {
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}
