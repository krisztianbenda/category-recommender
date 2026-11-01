// Typed configuration and structural validation.
// Contract: specs/001-local-llm-categorizer/contracts/config.md

export type EncryptionMode = "filevault" | "external-volume" | "sqlcipher";

export interface DeviceEntry {
  name: string;
  fingerprintSha256: string;
  user: string;
}

/** The only user in local mode (no TLS, no device allowlist). */
export const LOCAL_USER = "owner";

const LOOPBACK_BIND = new Set(["127.0.0.1", "::1", "localhost"]);

export interface Config {
  version: 1;
  server: {
    bindAddress: string;
    port: number;
    /** null = local mode: plain HTTP on a loopback address, single owner, no device certs. */
    tls: { certFile: string; keyFile: string; clientCaFile: string } | null;
  };
  access: { devices: DeviceEntry[] };
  storage: { dataDir: string; encryption: EncryptionMode; sqlcipherKeyFile: string | null };
  llm: { baseUrl: string; model: string; maxEmailTokens: number; requestTimeoutSeconds: number };
  embeddings: { baseUrl: string; model: string };
  learning: {
    neighbours: number;
    fewShotExamples: number;
    recencyHalfLifeDays: number;
    /** Neighbours below this cosine similarity are ignored (votes and few-shot). */
    minSimilarity: number;
    confidence: { knnAgreeShare: number };
    /** Past decisions override the model when they agree this strongly. */
    override: { share: number; minExamples: number };
    newCategoryDuplicateSimilarity: number;
  };
  suggestions: { ttlSeconds: number };
  logging: { level: "fatal" | "error" | "warn" | "info" | "debug"; retentionDays: number };
  backup: { ageRecipient: string | null };
}

export class ConfigError extends Error {
  constructor(public readonly problems: string[]) {
    super(`Invalid configuration:\n- ${problems.join("\n- ")}`);
    this.name = "ConfigError";
  }
}

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

class Reader {
  readonly problems: string[] = [];

  obj(parent: Obj, key: string, path: string): Obj {
    const v = parent[key];
    if (v === undefined) return {};
    if (!isObj(v)) {
      this.problems.push(`${path} must be an object`);
      return {};
    }
    return v;
  }

  str(o: Obj, key: string, path: string, def?: string): string {
    const v = o[key] ?? def;
    if (typeof v !== "string" || v.trim() === "") {
      this.problems.push(`${path} must be a non-empty string`);
      return "";
    }
    return v;
  }

  optStr(o: Obj, key: string, path: string): string | null {
    const v = o[key];
    if (v === undefined || v === null) return null;
    if (typeof v !== "string" || v.trim() === "") {
      this.problems.push(`${path} must be a non-empty string or null`);
      return null;
    }
    return v;
  }

  num(
    o: Obj,
    key: string,
    path: string,
    def: number,
    min: number,
    max: number,
    int = true,
  ): number {
    const v = o[key] ?? def;
    if (
      typeof v !== "number" ||
      Number.isNaN(v) ||
      v < min ||
      v > max ||
      (int && !Number.isInteger(v))
    ) {
      this.problems.push(
        `${path} must be ${int ? "an integer" : "a number"} between ${min} and ${max}`,
      );
      return def;
    }
    return v;
  }

  oneOf<T extends string>(o: Obj, key: string, path: string, allowed: readonly T[], def: T): T {
    const v = o[key] ?? def;
    if (typeof v !== "string" || !allowed.includes(v as T)) {
      this.problems.push(`${path} must be one of ${allowed.join(", ")}`);
      return def;
    }
    return v as T;
  }
}

const FINGERPRINT = /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/;

export function normaliseFingerprint(fp: string): string {
  return fp.trim().toUpperCase();
}

export function parseDevices(raw: unknown, problems: string[]): DeviceEntry[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    problems.push("access.devices must be a list");
    return [];
  }
  const out: DeviceEntry[] = [];
  raw.forEach((d, i) => {
    const p = `access.devices[${i}]`;
    if (!isObj(d)) {
      problems.push(`${p} must be an object`);
      return;
    }
    const name = typeof d.name === "string" ? d.name.trim() : "";
    const fp =
      typeof d.fingerprintSha256 === "string" ? normaliseFingerprint(d.fingerprintSha256) : "";
    const user = typeof d.user === "string" ? d.user.trim() : "";
    if (!name) problems.push(`${p}.name must be a non-empty string`);
    if (!FINGERPRINT.test(fp))
      problems.push(`${p}.fingerprintSha256 must be a SHA-256 fingerprint (AA:BB:...)`);
    if (!/^[a-z][a-z0-9_-]{0,31}$/.test(user))
      problems.push(`${p}.user must be a short lower-case id`);
    out.push({ name, fingerprintSha256: fp, user });
  });
  return out;
}

/** Structural validation only. Host-dependent checks live in load.ts. */
export function validateConfig(raw: unknown): Config {
  const r = new Reader();
  if (!isObj(raw)) throw new ConfigError(["configuration root must be an object"]);
  if (raw.version !== 1) r.problems.push("version must be 1");

  const server = r.obj(raw, "server", "server");
  const localMode = server.tls === undefined || server.tls === null;
  const tls = r.obj(server, "tls", "server.tls");
  const access = r.obj(raw, "access", "access");
  const storage = r.obj(raw, "storage", "storage");
  const llm = r.obj(raw, "llm", "llm");
  const emb = r.obj(raw, "embeddings", "embeddings");
  const learning = r.obj(raw, "learning", "learning");
  const conf = r.obj(learning, "confidence", "learning.confidence");
  const override = r.obj(learning, "override", "learning.override");
  const sugg = r.obj(raw, "suggestions", "suggestions");
  const logging = r.obj(raw, "logging", "logging");
  const backup = r.obj(raw, "backup", "backup");

  const config: Config = {
    version: 1,
    server: {
      bindAddress: r.str(server, "bindAddress", "server.bindAddress"),
      port: r.num(server, "port", "server.port", 8443, 1, 65535),
      tls: localMode
        ? null
        : {
            certFile: r.str(tls, "certFile", "server.tls.certFile"),
            keyFile: r.str(tls, "keyFile", "server.tls.keyFile"),
            clientCaFile: r.str(tls, "clientCaFile", "server.tls.clientCaFile"),
          },
    },
    access: { devices: parseDevices(access.devices, r.problems) },
    storage: {
      dataDir: r.str(storage, "dataDir", "storage.dataDir"),
      encryption: r.oneOf(
        storage,
        "encryption",
        "storage.encryption",
        ["filevault", "external-volume", "sqlcipher"] as const,
        "filevault",
      ),
      sqlcipherKeyFile: r.optStr(storage, "sqlcipherKeyFile", "storage.sqlcipherKeyFile"),
    },
    llm: {
      baseUrl: r.str(llm, "baseUrl", "llm.baseUrl"),
      model: r.str(llm, "model", "llm.model"),
      maxEmailTokens: r.num(llm, "maxEmailTokens", "llm.maxEmailTokens", 1500, 100, 32000),
      requestTimeoutSeconds: r.num(
        llm,
        "requestTimeoutSeconds",
        "llm.requestTimeoutSeconds",
        30,
        1,
        600,
      ),
    },
    embeddings: {
      baseUrl: r.str(emb, "baseUrl", "embeddings.baseUrl"),
      model: r.str(emb, "model", "embeddings.model"),
    },
    learning: {
      neighbours: r.num(learning, "neighbours", "learning.neighbours", 8, 1, 100),
      fewShotExamples: r.num(learning, "fewShotExamples", "learning.fewShotExamples", 5, 0, 20),
      recencyHalfLifeDays: r.num(
        learning,
        "recencyHalfLifeDays",
        "learning.recencyHalfLifeDays",
        180,
        1,
        3650,
      ),
      minSimilarity: r.num(learning, "minSimilarity", "learning.minSimilarity", 0.5, 0, 1, false),
      override: {
        share: r.num(override, "share", "learning.override.share", 0.75, 0, 1, false),
        minExamples: r.num(override, "minExamples", "learning.override.minExamples", 3, 1, 100),
      },
      confidence: {
        knnAgreeShare: r.num(
          conf,
          "knnAgreeShare",
          "learning.confidence.knnAgreeShare",
          0.6,
          0,
          1,
          false,
        ),
      },
      newCategoryDuplicateSimilarity: r.num(
        learning,
        "newCategoryDuplicateSimilarity",
        "learning.newCategoryDuplicateSimilarity",
        0.9,
        0,
        1,
        false,
      ),
    },
    suggestions: {
      ttlSeconds: r.num(sugg, "ttlSeconds", "suggestions.ttlSeconds", 3600, 10, 86400),
    },
    logging: {
      level: r.oneOf(
        logging,
        "level",
        "logging.level",
        ["fatal", "error", "warn", "info", "debug"] as const,
        "info",
      ),
      retentionDays: r.num(logging, "retentionDays", "logging.retentionDays", 14, 1, 365),
    },
    backup: { ageRecipient: r.optStr(backup, "ageRecipient", "backup.ageRecipient") },
  };

  if (config.storage.encryption === "sqlcipher" && !config.storage.sqlcipherKeyFile) {
    r.problems.push("storage.sqlcipherKeyFile is required when storage.encryption is sqlcipher");
  }
  if (localMode && !LOOPBACK_BIND.has(config.server.bindAddress)) {
    r.problems.push(
      "server.bindAddress must be 127.0.0.1, ::1 or localhost when server.tls is not set",
    );
  }
  if (r.problems.length) throw new ConfigError(r.problems);
  return config;
}
