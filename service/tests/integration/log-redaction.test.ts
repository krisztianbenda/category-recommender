import { Writable } from "node:stream";
import { describe, expect, it } from "vitest";
import { createLogger, redact } from "../../src/logging/logger.js";
import { startTestApp } from "../helpers/app.js";

const SECRETS = [
  "Synthetic Sender <s@example.test>",
  "SYNTHETIC-SECRET-SUBJECT",
  "Family/Baby",
  "synthetic body text about a fabricated gathering",
];

function capture() {
  const lines: string[] = [];
  const stream = new Writable({
    write(chunk, _enc, cb) {
      lines.push(chunk.toString());
      cb();
    },
  });
  return { lines, logger: createLogger({ level: "debug", destination: stream }) };
}

describe("log redaction", () => {
  it("drops every key outside the allowlist", () => {
    const { lines, logger } = capture();
    logger.info(
      {
        reqId: "req-1",
        status: 200,
        // @ts-expect-error: deliberately passing forbidden keys
        from: SECRETS[0],
        subject: SECRETS[1],
        category: SECRETS[2],
        body: SECRETS[3],
        email: { from: SECRETS[0], subject: SECRETS[1] },
      },
      "request",
    );
    const out = lines.join("");
    for (const s of SECRETS) expect(out).not.toContain(s);
    expect(out).toContain("req-1");
  });

  it("drops objects even under allowed keys", () => {
    expect(redact({ errorCode: { subject: SECRETS[1] }, count: 3 })).toEqual({ count: 3 });
  });

  it("logs nothing personal during real requests", async () => {
    const { lines, logger } = capture();
    const t = await startTestApp({ logger });
    try {
      await t.call("POST", "/v1/suggestions", {
        email: { from: SECRETS[0], subject: SECRETS[1], body: SECRETS[3] },
        categories: [SECRETS[2], "Gadgets"],
      });
      await t.call("POST", "/v1/suggestions", { email: { from: SECRETS[0], subject: SECRETS[1] } });
    } finally {
      await t.close();
    }
    const out = lines.join("");
    expect(lines.length).toBeGreaterThan(0);
    for (const s of SECRETS) expect(out).not.toContain(s);
    expect(out).not.toContain("Baby");
  });
});
