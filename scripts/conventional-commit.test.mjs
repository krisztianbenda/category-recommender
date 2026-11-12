// Tests for the commit message and pull request title check: node --test scripts/
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { check, clean, MAX_HEADER, MAX_TITLE } from "./conventional-commit.mjs";

const SCRIPT = fileURLToPath(new URL("./conventional-commit.mjs", import.meta.url));

test("accepts the forms the project uses", () => {
  for (const m of [
    "feat: macOS Mail integration and delete suggestions",
    "feat(web): keep typed content when switching tabs",
    "fix!: drop the v0 config format",
    "build(deps): bump undici from 8.12.2 to 8.12.3",
    "docs: licence, install and usage guide (#1)",
    "chore: pin model checksums\n\nThe body explains why.\n\nCo-Authored-By: Someone <someone@example.test>",
  ]) {
    assert.deepEqual(check(m), [], m);
  }
});

test("rejects a message without a type", () => {
  assert.equal(check("Update README.md").length, 1);
  assert.equal(check("feat add a thing").length, 1);
  assert.equal(check("feat:missing space").length, 1);
  assert.equal(check("feat(): empty scope").length, 1);
});

test("rejects an unknown type and says which ones exist", () => {
  const [error] = check("feature: add a thing");
  assert.match(error, /"feature" is not a type/);
  assert.match(error, /feat, fix/);
  assert.equal(check("Feat: add a thing").length, 1);
});

test("rejects a trailing full stop, a long first line and a missing blank line", () => {
  assert.deepEqual(check("fix: stop the crash."), [
    "the description must not end with a full stop",
  ]);
  assert.match(check(`feat: ${"x".repeat(MAX_HEADER)}`)[0], /characters/);
  assert.deepEqual(check("fix: stop the crash\nmore text"), [
    "leave a blank line between the first line and the body",
  ]);
});

test("lets through what git and GitHub write themselves", () => {
  for (const m of [
    "Merge branch 'main' into claude/feature",
    "Merge pull request #12 from someone/branch",
    'Revert "feat: add a thing"',
    "fixup! feat: add a thing",
    "squash! fix: stop the crash",
  ]) {
    assert.deepEqual(check(m), [], m);
  }
});

test("a pull request title lands on main as it is, so it gets no commit-only leniency", () => {
  const title = (t) => check(t, { title: true });
  assert.deepEqual(title("ci: check pull request titles"), []);
  assert.deepEqual(title('Revert "feat: add a thing"'), []);
  for (const t of ["fixup! feat: add a thing", "squash! fix: x", "Merge branch 'main' into x"]) {
    assert.equal(title(t).length, 1, t);
  }
  assert.match(title("#12 feat: add a thing")[0], /the title must look like/);
  assert.deepEqual(title(""), ["the title is empty"]);
  assert.deepEqual(title(`feat: ${"x".repeat(MAX_TITLE - 6)}`), []);
  assert.match(title(`feat: ${"x".repeat(MAX_TITLE - 5)}`)[0], /keep it to 92/);
});

test("ignores comment lines and everything below the scissors line, like git", () => {
  const edited = [
    "# Please enter the commit message for your changes.",
    "feat: add a thing",
    "",
    "# On branch main",
    "# ------------------------ >8 ------------------------",
    "diff --git a/x b/x",
  ].join("\n");
  assert.equal(clean(edited), "feat: add a thing");
  assert.deepEqual(check(edited), []);
  assert.deepEqual(check("# only a comment\n"), ["the message is empty"]);
});

test("the command exits 1 for a bad message file or title and 0 for a good one", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "commit-msg-"));
  const file = path.join(dir, "COMMIT_EDITMSG");
  const run = (...args) => {
    try {
      execFileSync(process.execPath, [SCRIPT, ...args], { stdio: "pipe" });
      return 0;
    } catch (e) {
      return e.status;
    }
  };
  try {
    fs.writeFileSync(file, "feat: add a thing\n");
    assert.equal(run(file), 0);
    fs.writeFileSync(file, "added a thing\n");
    assert.equal(run(file), 1);
    assert.equal(run("--title=ci: check pull request titles"), 0);
    assert.equal(run("--title=Add CI"), 1);
    assert.equal(run("--title=-WIP- fix: x"), 1);
    assert.equal(run("--title=fixup! fix: x"), 1);
    assert.equal(run(), 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
