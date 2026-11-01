// `catrec restore <file> --identity <key>`: decrypts a backup into storage.dataDir (R16).
// Stop the service first. Embeddings are re-computed at service start when the embedding model
// differs from the one recorded in the backup.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Config } from "../config/schema.js";
import { dbFileFor, migrate, openDb } from "../store/db.js";
import { ageBin, type Manifest } from "./backup.js";

export interface RestoreResult {
  manifest: Manifest;
  previousMovedTo: string | null;
}

export function restore(
  config: Config,
  inFile: string,
  identityFile: string,
  opts: { force?: boolean } = {},
): RestoreResult {
  const dataDir = config.storage.dataDir;
  const dbFile = dbFileFor(dataDir);
  const exists = fs.existsSync(dbFile);
  if (exists && !opts.force) {
    throw new Error("storage.dataDir already has a database; pass --force to replace it");
  }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-restore-"));
  try {
    execFileSync(ageBin(), ["-d", "-i", identityFile, "-o", path.join(tmp, "bundle.tgz"), inFile], {
      stdio: "inherit",
    });
    execFileSync("tar", ["-xzf", path.join(tmp, "bundle.tgz"), "-C", tmp]);
    const manifest = JSON.parse(
      fs.readFileSync(path.join(tmp, "manifest.json"), "utf8"),
    ) as Manifest;
    if (manifest.version !== 1) throw new Error("unsupported backup version");

    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    let previousMovedTo: string | null = null;
    if (exists) {
      previousMovedTo = `${dbFile}.before-restore-${Date.now()}`;
      fs.renameSync(dbFile, previousMovedTo);
    }
    for (const suffix of ["-wal", "-shm"]) fs.rmSync(dbFile + suffix, { force: true });
    fs.copyFileSync(path.join(tmp, "catrec.db"), dbFile);
    fs.chmodSync(dbFile, 0o600);
    fs.copyFileSync(path.join(tmp, "config.yaml"), path.join(dataDir, "restored-config.yaml"));

    const db = openDb(dbFile);
    try {
      migrate(db); // bring an older backup up to the current schema
    } finally {
      db.close();
    }
    return { manifest, previousMovedTo };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
