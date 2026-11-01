#!/usr/bin/env node
// catrec admin CLI: backup and restore (research R16, docs/operations.md).
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { configPathFromEnv, findRepoRoot, isInside, loadConfig } from "../config/load.js";
import { backup } from "./backup.js";
import { restore } from "./restore.js";

const USAGE = `usage:
  catrec backup <file.age>
  catrec restore <file.age> --identity <age-identity-file> [--force]

CATREC_CONFIG must point at the service config.`;

export async function run(argv: string[]): Promise<number> {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: { identity: { type: "string" }, force: { type: "boolean", default: false } },
  });
  const [command, file] = positionals;
  if (!command || !file) {
    process.stderr.write(`${USAGE}\n`);
    return 2;
  }
  const configFile = configPathFromEnv();
  const config = loadConfig(configFile);
  const target = path.resolve(file);
  const repo = findRepoRoot(path.dirname(fileURLToPath(import.meta.url)));

  switch (command) {
    case "backup":
      if (repo && isInside(target, repo)) throw new Error("write backups outside the repository");
      await backup(config, configFile, target);
      process.stdout.write(`backup written to ${target}\n`);
      return 0;
    case "restore": {
      if (!values.identity) throw new Error("--identity is required for restore");
      const r = restore(config, target, values.identity, { force: values.force });
      process.stdout.write(
        `restored backup from ${r.manifest.createdAt} (embeddings: ${r.manifest.embeddingModel})\n` +
          (r.previousMovedTo ? `previous database kept at ${r.previousMovedTo}\n` : "") +
          "start the service; examples are re-embedded automatically if the embedding model changed\n",
      );
      return 0;
    }
    default:
      process.stderr.write(`${USAGE}\n`);
      return 2;
  }
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (isMain) {
  run(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`catrec: ${(e as Error).message}\n`);
      process.exit(1);
    },
  );
}
