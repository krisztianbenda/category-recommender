// `catrec backup <file>`: online SQLite backup + config, tarred and encrypted with age (R16).
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import Database from "better-sqlite3";
import type { Config } from "../config/schema.js";
import { dbFileFor } from "../store/db.js";

export const ageBin = (): string => process.env.CATREC_AGE_BIN ?? "age";

export interface Manifest {
  version: 1;
  createdAt: string;
  embeddingModel: string;
  migrations: string[];
}

export async function backup(config: Config, configFile: string, outFile: string): Promise<void> {
  const recipient = config.backup.ageRecipient;
  if (!recipient) throw new Error("backup.ageRecipient is not set in the config");
  const dbFile = dbFileFor(config.storage.dataDir);
  if (!fs.existsSync(dbFile)) throw new Error("no database found in storage.dataDir");

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-backup-"));
  try {
    const db = new Database(dbFile, { readonly: true, fileMustExist: true });
    try {
      await db.backup(path.join(tmp, "catrec.db"));
      const migrations = (
        db.prepare("SELECT name FROM schema_migrations ORDER BY name").all() as { name: string }[]
      ).map((r) => r.name);
      const manifest: Manifest = {
        version: 1,
        createdAt: new Date().toISOString(),
        embeddingModel: config.embeddings.model,
        migrations,
      };
      fs.writeFileSync(path.join(tmp, "manifest.json"), JSON.stringify(manifest, null, 2));
    } finally {
      db.close();
    }
    // The config references secrets by path only, so it is safe to include.
    fs.copyFileSync(configFile, path.join(tmp, "config.yaml"));
    execFileSync("tar", [
      "-czf",
      path.join(tmp, "bundle.tgz"),
      "-C",
      tmp,
      "catrec.db",
      "manifest.json",
      "config.yaml",
    ]);
    execFileSync(ageBin(), ["-r", recipient, "-o", outFile, path.join(tmp, "bundle.tgz")], {
      stdio: "inherit",
    });
    fs.chmodSync(outFile, 0o600);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
