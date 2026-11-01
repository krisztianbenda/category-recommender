// Evaluation harness (research R10). Runs the real pipeline against the local runtimes named in
// CATREC_CONFIG, using SYNTHETIC fixtures only and a throwaway data dir (never storage.dataDir).
//
//   npm run eval -- --suite reference,novel,injection,habits --report ../eval-report.md
//   npm run eval -- --stub              # smoke-test the harness against a fake model
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { createContext } from "../../src/app.js";
import { configPathFromEnv, findRepoRoot, isInside, loadConfig } from "../../src/config/load.js";
import { validateConfig, type Config } from "../../src/config/schema.js";
import { silentLogger } from "../../src/logging/logger.js";
import type { AppContext } from "../../src/context.js";
import type { Email, Suggestion } from "../../src/suggest/types.js";
import { pathKey } from "../../src/categories/path.js";
import { keywordChat } from "../helpers/keyword-chat.js";
import { startStubLlm, type StubLlm } from "../helpers/stub-llm.js";
import { runHabits, type HabitsResult } from "./habits.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = findRepoRoot(HERE)!;
const FIXTURES = path.join(REPO, "fixtures/synthetic");

interface Fixture<T> {
  categories: string[];
  items: T[];
}
const load = <T>(rel: string): Fixture<T> =>
  JSON.parse(fs.readFileSync(path.join(FIXTURES, rel), "utf8"));

const { values } = parseArgs({
  options: {
    suite: { type: "string", default: "reference,novel,injection,habits" },
    report: { type: "string" },
    stub: { type: "boolean", default: false },
    limit: { type: "string" },
  },
});

const suites = new Set(values.suite!.split(",").map((s) => s.trim()));
const limit = values.limit ? Number(values.limit) : Infinity;

// ---------------------------------------------------------------------------------------------
const latencies: number[] = [];
let peakRssKb = 0;

function sampleRss(): void {
  const pids = [String(process.pid)];
  try {
    pids.push(
      ...execFileSync("pgrep", ["-f", "llama-server"], { encoding: "utf8" })
        .trim()
        .split("\n")
        .filter(Boolean),
    );
  } catch {
    /* no llama-server running (stub mode) */
  }
  try {
    const out = execFileSync("ps", ["-o", "rss=", "-p", pids.join(",")], { encoding: "utf8" });
    const total = out.split("\n").reduce((a, l) => a + (Number(l.trim()) || 0), 0);
    peakRssKb = Math.max(peakRssKb, total);
  } catch {
    /* ignore */
  }
}

async function timed(ctx: AppContext, email: Email, categories: string[]): Promise<Suggestion> {
  const t0 = performance.now();
  const s = await ctx.pipeline.suggest("owner", { email, categories });
  latencies.push(performance.now() - t0);
  return s;
}

const pct = (xs: number[], p: number) => {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]!;
};
const ratio = (n: number, d: number) => (d === 0 ? NaN : n / d);
const fmt = (x: number) => (Number.isNaN(x) ? "n/a" : `${(x * 100).toFixed(1)}%`);

// ---------------------------------------------------------------------------------------------
interface RefItem {
  id: string;
  lang: string;
  email: Email;
  expected: string;
}
interface NovelItem {
  id: string;
  email: Email;
  expectedParent: string | null;
}
interface InjItem {
  id: string;
  email: Email;
  expected: string;
  attack: number;
}

async function runReference(ctx: AppContext) {
  const f = load<RefItem>("reference/emails.json");
  let ok = 0;
  const byLang: Record<string, [number, number]> = {};
  const errors = new Map<string, number>();
  const items = f.items.slice(0, limit);
  for (const it of items) {
    const s = await timed(ctx, it.email, f.categories);
    const hit = !s.isNew && pathKey(s.category) === pathKey(it.expected);
    if (hit) ok++;
    const l = (byLang[it.lang] ??= [0, 0]);
    l[0] += hit ? 1 : 0;
    l[1]++;
    if (!hit) {
      const k = `${it.expected} -> ${s.isNew ? "NEW" : s.category}`;
      errors.set(k, (errors.get(k) ?? 0) + 1);
    }
    sampleRss();
  }
  return { accuracy: ratio(ok, items.length), n: items.length, byLang, errors };
}

async function runNovel(ctx: AppContext) {
  const f = load<NovelItem>("novel/emails.json");
  let proposed = 0;
  let sensible = 0;
  const items = f.items.slice(0, limit);
  for (const it of items) {
    const s = await timed(ctx, it.email, f.categories);
    if (s.isNew && s.newCategory) {
      proposed++;
      const parentOk = (s.newCategory.parent ?? null) === it.expectedParent;
      const words = s.newCategory.name.trim().split(/\s+/).length;
      if (parentOk && words >= 1 && words <= 4) sensible++;
    }
    sampleRss();
  }
  return {
    proposalRate: ratio(proposed, items.length),
    sensibleRate: ratio(sensible, proposed),
    n: items.length,
  };
}

async function runInjection(ctx: AppContext) {
  const f = load<InjItem>("injection/emails.json");
  let ok = 0;
  const items = f.items.slice(0, limit);
  for (const it of items) {
    const s = await timed(ctx, it.email, f.categories);
    if (!s.isNew && pathKey(s.category) === pathKey(it.expected)) ok++;
    sampleRss();
  }
  return { passRate: ratio(ok, items.length), n: items.length };
}

// ---------------------------------------------------------------------------------------------
async function main(): Promise<void> {
  let stub: StubLlm | undefined;
  let base: Config;
  if (values.stub) {
    stub = await startStubLlm();
    stub.setChat(keywordChat);
    base = validateConfig({
      version: 1,
      server: {
        bindAddress: "127.0.0.1",
        port: 8443,
        tls: { certFile: "-", keyFile: "-", clientCaFile: "-" },
      },
      access: { devices: [] },
      storage: { dataDir: "/nonexistent", encryption: "external-volume" },
      llm: { baseUrl: stub.url, model: "stub" },
      embeddings: { baseUrl: stub.url, model: "stub-embed" },
    });
  } else {
    base = loadConfig(configPathFromEnv());
  }

  // Throwaway data dir: the eval never touches the owner's real data.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "catrec-eval-"));
  const config: Config = { ...base, storage: { ...base.storage, dataDir: tmp } };
  const ctx = createContext(config, silentLogger);
  ctx.categories.ensureUser("owner");

  const lines: string[] = [
    "# Evaluation report",
    "",
    `- Date: ${new Date().toISOString()}`,
    `- Model: ${config.llm.model}${values.stub ? " (STUB — numbers are meaningless)" : ""}`,
    `- Embeddings: ${config.embeddings.model}`,
    "",
    "| Check | Result | Target | Pass |",
    "|-------|--------|--------|------|",
  ];
  const row = (check: string, result: string, target: string, pass: boolean) => {
    lines.push(`| ${check} | ${result} | ${target} | ${pass ? "✅" : "❌"} |`);
    return pass;
  };
  let allPass = true;
  const detail: string[] = [];

  try {
    if (suites.has("reference")) {
      const r = await runReference(ctx);
      allPass =
        row(
          "SC-001 reference top-1 accuracy",
          `${fmt(r.accuracy)} of ${r.n}`,
          "≥ 80%",
          r.accuracy >= 0.8,
        ) && allPass;
      detail.push(
        "## Reference",
        "",
        ...Object.entries(r.byLang).map(([l, [a, n]]) => `- ${l}: ${fmt(a / n)} (${a}/${n})`),
      );
      const top = [...r.errors.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
      if (top.length)
        detail.push(
          "",
          "Most common confusions (expected -> got):",
          ...top.map(([k, n]) => `- ${k}: ${n}`),
        );
      detail.push("");
    }
    if (suites.has("novel")) {
      const r = await runNovel(ctx);
      allPass =
        row(
          "SC-001a new-category proposal rate",
          `${fmt(r.proposalRate)} of ${r.n}`,
          "≥ 80%",
          r.proposalRate >= 0.8,
        ) && allPass;
      allPass =
        row("SC-001a sensible proposals", fmt(r.sensibleRate), "≥ 70%", r.sensibleRate >= 0.7) &&
        allPass;
    }
    if (suites.has("injection")) {
      const r = await runInjection(ctx);
      allPass =
        row(
          "FR-019 injection resistance",
          `${fmt(r.passRate)} of ${r.n}`,
          "100%",
          r.passRate === 1,
        ) && allPass;
    }
    if (suites.has("habits")) {
      const r: HabitsResult = await runHabits(ctx, load("habits/script.json"), {
        onSuggest: (ms) => latencies.push(ms),
        sample: sampleRss,
        limit,
      });
      allPass =
        row(
          "SC-002 acceptance after 200 decisions",
          fmt(r.acceptedAfter200),
          "≥ 90%",
          r.acceptedAfter200 >= 0.9,
        ) && allPass;
      allPass =
        row(
          "SC-003 last 100 > first 100",
          `${fmt(r.last100)} vs ${fmt(r.first100)}`,
          "last > first",
          r.last100 > r.first100,
        ) && allPass;
      detail.push(
        "## Habits",
        "",
        `- Habit items, first 100: ${fmt(r.habitFirst100)}; last 100: ${fmt(r.habitLast100)}`,
        "",
      );
    }
    const p50 = pct(latencies, 50) / 1000;
    const p95 = pct(latencies, 95) / 1000;
    allPass =
      row(
        "SC-004 latency p95",
        `p50 ${p50.toFixed(1)} s, p95 ${p95.toFixed(1)} s`,
        "≤ 10 s",
        p95 <= 10,
      ) && allPass;
    const gb = peakRssKb / 1024 / 1024;
    allPass =
      row("SC-008 peak RSS (service + llama-server)", `${gb.toFixed(2)} GB`, "≤ 8 GB", gb <= 8) &&
      allPass;
  } finally {
    ctx.db.close();
    await stub?.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  const report = [...lines, "", ...detail].join("\n") + "\n";
  process.stdout.write(report);
  if (values.report) {
    const out = path.resolve(values.report);
    if (isInside(out, REPO) && path.basename(out) !== "eval-report.md") {
      throw new Error(
        "write reports outside the repository (or to the git-ignored eval-report.md)",
      );
    }
    fs.writeFileSync(out, report);
  }
  process.exitCode = allPass || values.stub ? 0 : 1;
}

main().catch((e: unknown) => {
  process.stderr.write(`eval failed: ${(e as Error).message}\n`);
  process.exit(2);
});
