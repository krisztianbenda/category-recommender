import { request } from "undici";
import { Agent } from "undici";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startTestApp, type TestApp } from "../helpers/app.js";

let t: TestApp;

beforeAll(async () => {
  t = await startTestApp();
});
afterAll(async () => t.close());

async function waitFor(check: () => Promise<boolean>, timeoutMs: number): Promise<boolean> {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (await check()) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

describe("mutual TLS access control (quickstart V10)", () => {
  it("rejects a client without a certificate during the handshake", async () => {
    const agent = new Agent({ connect: { ca: t.pki.ca, servername: "localhost" } });
    await expect(
      request(`${t.baseUrl}/v1/health`, { dispatcher: agent }).then((r) => r.body.text()),
    ).rejects.toThrow();
    await agent.close();
  });

  it("rejects a certificate from another CA during the handshake", async () => {
    const rogue = t.pki.issueClient("rogue", { selfSigned: true });
    await expect(t.call("GET", "/v1/health", undefined, rogue)).rejects.toThrow();
  });

  it("returns 403 for a CA-signed certificate that is not allowlisted", async () => {
    const unknown = t.pki.issueClient("unknown-tablet");
    const res = await t.call<{ error: { code: string } }>("GET", "/v1/health", undefined, unknown);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("forbidden");
  });

  it("allows an allowlisted device", async () => {
    const res = await t.call<{ status: string }>("GET", "/v1/health");
    expect(res.status).toBe(200);
    expect(res.body.status).toBe("ok");
  });

  it("adds and revokes devices from config without a restart", async () => {
    const phone = t.pki.issueClient("owner-phone");
    expect((await t.call("GET", "/v1/health", undefined, phone)).status).toBe(403);

    t.writeConfig((c: any) =>
      c.access.devices.push({
        name: phone.name,
        fingerprintSha256: phone.fingerprint,
        user: "owner",
      }),
    );
    expect(
      await waitFor(
        async () => (await t.call("GET", "/v1/health", undefined, phone)).status === 200,
        5000,
      ),
    ).toBe(true);

    t.writeConfig((c: any) => {
      c.access.devices = c.access.devices.filter((d: any) => d.name !== phone.name);
    });
    expect(
      await waitFor(
        async () => (await t.call("GET", "/v1/health", undefined, phone)).status === 403,
        5000,
      ),
    ).toBe(true);
    // the remaining device still works
    expect((await t.call("GET", "/v1/health")).status).toBe(200);
  });
});
