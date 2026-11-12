#!/usr/bin/env node
// Checks a commit message or a pull request title against Conventional Commits 1.0.0
// (https://www.conventionalcommits.org/en/v1.0.0/). It has no dependencies, so the git hook
// works in every clone and worktree without an install.
//
//   node scripts/conventional-commit.mjs .git/COMMIT_EDITMSG    # the commit-msg hook
//   node scripts/conventional-commit.mjs --title "feat: add X"   # a pull request title (CI)
//
// Pull requests are squash-merged and the title becomes the commit on main, so CI checks it.
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export const TYPES = [
  "build",
  "chore",
  "ci",
  "docs",
  "feat",
  "fix",
  "perf",
  "refactor",
  "revert",
  "style",
  "test",
];
export const MAX_HEADER = 100;

const HEADER = /^(?<type>\w+)(?:\((?<scope>[^()\s][^()]*)\))?(?<breaking>!)?: (?<subject>\S.*)$/;

/** Messages that git or GitHub write, and fixups that are squashed away before a merge. */
const EXEMPT = [
  /^Merge (branch|branches|pull request|remote-tracking branch|tag|commit) /,
  /^Revert ".+"/,
  /^(fixup|squash|amend)! /,
];

/** What git keeps of an edited message: no comment lines, nothing below the scissors line. */
export function clean(message) {
  const lines = message.replace(/\r\n/g, "\n").split("\n");
  const scissors = lines.findIndex((l) => /^# -+ >8 -+$/.test(l));
  return (scissors >= 0 ? lines.slice(0, scissors) : lines)
    .filter((l) => !l.startsWith("#"))
    .join("\n")
    .trim();
}

/** Returns what is wrong with the message, or nothing when it is a valid Conventional Commit. */
export function check(message) {
  const text = clean(message);
  if (!text) return ["the message is empty"];
  const [header, second] = text.split("\n");
  if (EXEMPT.some((re) => re.test(header))) return [];

  const errors = [];
  const m = HEADER.exec(header);
  if (!m) {
    errors.push(`the first line must look like "<type>(<optional scope>): <description>"`);
  } else {
    const { type, subject } = m.groups;
    if (!TYPES.includes(type))
      errors.push(`"${type}" is not a type; use one of: ${TYPES.join(", ")}`);
    if (subject.endsWith(".")) errors.push("the description must not end with a full stop");
  }
  if (header.length > MAX_HEADER) {
    errors.push(`the first line is ${header.length} characters; keep it to ${MAX_HEADER}`);
  }
  if (second !== undefined && second.trim() !== "") {
    errors.push("leave a blank line between the first line and the body");
  }
  return errors;
}

function main() {
  const { values, positionals } = parseArgs({
    options: { title: { type: "string" } },
    allowPositionals: true,
  });
  let message;
  let what;
  if (values.title !== undefined) {
    message = values.title;
    what = "pull request title";
  } else if (positionals.length === 1) {
    message = fs.readFileSync(positionals[0], "utf8");
    what = "commit message";
  } else {
    process.stderr.write("usage: conventional-commit.mjs <message-file> | --title <title>\n");
    process.exit(2);
  }
  const errors = check(message);
  if (errors.length === 0) return;
  process.stderr.write(
    [
      `✖ The ${what} is not a Conventional Commit:`,
      `    ${clean(message).split("\n")[0] || "(empty)"}`,
      ...errors.map((e) => `  - ${e}`),
      "",
      "  For example:  feat(web): keep typed content when switching tabs",
      "                fix!: drop the v0 config format",
      `  Types: ${TYPES.join(", ")}. See https://www.conventionalcommits.org/en/v1.0.0/`,
      "",
    ].join("\n"),
  );
  process.exit(1);
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
