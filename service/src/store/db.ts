import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";

export type Db = Database.Database;

const MIGRATIONS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "migrations");

export function openDb(file: string): Db {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const db = new Database(file);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("secure_delete = ON"); // deleted content is overwritten, not left in free pages
  return db;
}

export function dbFileFor(dataDir: string): string {
  return path.join(dataDir, "catrec.db");
}

/**
 * Applies migrations/*.sql in name order, each once, tracked in schema_migrations.
 *
 * Some migrations rebuild a table, which SQLite only allows safely with foreign keys off: with
 * them on, dropping the old table would run its ON DELETE actions on the rows that point at it.
 * So foreign keys are off while migrations run, and each migration is checked before it commits.
 */
export function migrate(db: Db, dir = MIGRATIONS_DIR): string[] {
  const foreignKeys = db.pragma("foreign_keys", { simple: true }) === 1;
  db.pragma("foreign_keys = OFF");
  try {
    return applyMigrations(db, dir);
  } finally {
    if (foreignKeys) db.pragma("foreign_keys = ON");
  }
}

function applyMigrations(db: Db, dir: string): string[] {
  db.exec(
    "CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)",
  );
  const applied = new Set(
    db
      .prepare("SELECT name FROM schema_migrations")
      .all()
      .map((r) => (r as { name: string }).name),
  );
  const files = fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort();
  const ran: string[] = [];
  for (const f of files) {
    if (applied.has(f)) continue;
    const sql = fs.readFileSync(path.join(dir, f), "utf8");
    db.transaction(() => {
      db.exec(sql);
      const broken = db.pragma("foreign_key_check") as unknown[];
      if (broken.length) throw new Error(`migration ${f} left ${broken.length} broken references`);
      db.prepare("INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)").run(
        f,
        new Date().toISOString(),
      );
    })();
    ran.push(f);
  }
  return ran;
}
