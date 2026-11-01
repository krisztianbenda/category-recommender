import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";
import { ConfigError, validateConfig, type Config } from "./schema.js";

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "[::1]", "localhost"]);

export function isLoopbackUrl(url: string): boolean {
  try {
    const u = new URL(url);
    return (u.protocol === "http:" || u.protocol === "https:") && LOOPBACK_HOSTS.has(u.hostname);
  } catch {
    return false;
  }
}

/** Walks up from `start` to the first directory containing `.git`. */
export function findRepoRoot(start: string): string | null {
  let dir = path.resolve(start);
  for (;;) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/** realpath of the nearest existing ancestor, with the missing tail re-appended. */
function realpathLenient(p: string): string {
  let existing = path.resolve(p);
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    tail.unshift(path.basename(existing));
    const parent = path.dirname(existing);
    if (parent === existing) break;
    existing = parent;
  }
  return path.join(fs.realpathSync(existing), ...tail);
}

export function isInside(child: string, parent: string): boolean {
  const rel = path.relative(realpathLenient(parent), realpathLenient(child));
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function isWorldReadable(file: string): boolean {
  return (fs.statSync(file).mode & 0o004) !== 0;
}

export interface LoadOptions {
  /** Repository roots the data dir must not be inside. Defaults to the repo containing this code. */
  repoRoots?: string[];
}

function defaultRepoRoots(): string[] {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return [findRepoRoot(here), findRepoRoot(process.cwd())].filter((r): r is string => r !== null);
}

/** Host-dependent safety checks (constitution I, II). Throws ConfigError. */
export function checkHostRules(config: Config, opts: LoadOptions = {}): void {
  const problems: string[] = [];
  for (const root of opts.repoRoots ?? defaultRepoRoots()) {
    if (isInside(config.storage.dataDir, root)) {
      problems.push("storage.dataDir must be outside the repository working tree");
      break;
    }
  }
  if (!isLoopbackUrl(config.llm.baseUrl)) problems.push("llm.baseUrl must be a loopback address");
  if (!isLoopbackUrl(config.embeddings.baseUrl)) {
    problems.push("embeddings.baseUrl must be a loopback address");
  }
  const secrets: [string, string | null][] = [
    ["server.tls.keyFile", config.server.tls?.keyFile ?? null],
    ["storage.sqlcipherKeyFile", config.storage.sqlcipherKeyFile],
  ];
  for (const [key, file] of secrets) {
    if (!file) continue;
    if (!fs.existsSync(file)) problems.push(`${key} does not exist`);
    else if (isWorldReadable(file)) problems.push(`${key} must not be world-readable (chmod 600)`);
  }
  if (problems.length) throw new ConfigError(problems);
}

export function readConfigFile(file: string): unknown {
  return parseYaml(fs.readFileSync(file, "utf8"));
}

export function loadConfig(file: string, opts: LoadOptions = {}): Config {
  const config = validateConfig(readConfigFile(file));
  checkHostRules(config, opts);
  return config;
}

export function configPathFromEnv(): string {
  const p = process.env.CATREC_CONFIG;
  if (!p) throw new ConfigError(["CATREC_CONFIG environment variable is not set"]);
  return p;
}
