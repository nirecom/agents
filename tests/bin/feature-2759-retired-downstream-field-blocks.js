#!/usr/bin/env node
"use strict";
// Tests: bin/lib/check-migration-blocks/retired-tokens.txt, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js
// Tags: TL2, bin, migration-blocks, static-check, scope:issue-specific, pwsh-not-required
// #2759: the planned list of temporary blocks and of spellings of the retired field stays exact, so
// deleting the migration later means deleting exactly these places.
// TL3 gap (what this test does NOT catch):
// - a file not tracked yet: the scan reads `git ls-files`, so an unstaged new file is invisible.

const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const HOME_CWD = process.cwd();
const NEUTRAL = fs.mkdtempSync(path.join(os.tmpdir(), "f2759-blocks-"));
process.chdir(NEUTRAL);
after(() => {
  process.chdir(HOME_CWD);
  fs.rmSync(NEUTRAL, { recursive: true, force: true });
  restore();
});

const ROOT = path.resolve(__dirname, "..", "..");
const RT = require(path.join(ROOT, "bin", "lib", "check-migration-blocks", "retired-tokens.js"));
const MIGRATION_ID = "retired-downstream-field";
const PROJECTION = "hooks/workflow-state/state-io/projection.js";
const EVENTS = "hooks/workflow-state/state-io/events.js";
const T1 = "tests/hooks/feature-2759-retired-downstream-field.js";

function migration() {
  const parsed = RT.parseRegistry(fs.readFileSync(path.join(ROOT, RT.REG_REL), "utf8"));
  const found = parsed.migrations.find((m) => m.id === MIGRATION_ID);
  assert.ok(found, `the registry declares ${MIGRATION_ID}`);
  return found;
}

function tracked() {
  const env = { ...process.env };
  for (const name of Object.keys(env)) if (name.startsWith("GIT_")) delete env[name];
  const done = spawnSync("git", ["-C", ROOT, "ls-files", "-z"], { encoding: "utf8", env, maxBuffer: 256 * 1024 * 1024 });
  assert.strictEqual(done.status, 0, done.stderr);
  return done.stdout.split("\0").filter(Boolean);
}

function readTracked(rel) {
  try {
    return fs.readFileSync(path.join(ROOT, rel), "utf8");
  } catch {
    return "";
  }
}

const escapeRe = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const excepted = (m, rel) => rel === RT.REG_REL || m.excepts.some((x) => x.match.test(rel));

caseBegin("block-files-match-the-plan", "bin/lib/check-migration-blocks/retired-tokens.txt");
test("the tracked files with a block of this desc-key are exactly the planned list", () => {
  const begin = new RegExp(`-{3}\\s*${"BEGIN"}\\s+temporary:.*${escapeRe(migration().descKey)}`);
  const holders = tracked().filter((rel) => begin.test(readTracked(rel))).sort();
  assert.deepStrictEqual(holders, [EVENTS, PROJECTION, T1].sort());
});
caseEnd();

caseBegin("token-files-match-the-plan", "bin/lib/check-migration-blocks/retired-tokens.txt");
test("the token appears only in the projection module (one line) and in T1 (one line)", () => {
  const m = migration();
  assert.ok(m.tokens.length > 0, "the migration declares a token");
  const hits = {};
  for (const rel of tracked()) {
    if (excepted(m, rel)) continue;
    const lines = readTracked(rel).split(/\r?\n/).filter((line) => m.tokens.some((t) => t.re.test(line)));
    if (lines.length > 0) hits[rel] = lines.length;
  }
  assert.deepStrictEqual(hits, { [PROJECTION]: 1, [T1]: 1 });
});
caseEnd();

caseBegin("exports-never-spell-the-field", "hooks/workflow-state/state-io/projection.js");
test("the projection exports add the predicate, and no export name or value carries the token", () => {
  const m = migration();
  const exported = require(path.join(ROOT, PROJECTION));
  assert.strictEqual(typeof exported.eventCarriesRetiredDownstreamField, "function", "the predicate is exported");
  const carries = (text) => m.tokens.some((t) => t.re.test(text));
  for (const [name, value] of Object.entries(exported)) {
    assert.ok(!carries(name), `export name ${name}`);
    if (typeof value === "function") continue;
    assert.ok(!carries(JSON.stringify(value) || ""), `export value ${name}`);
  }
});
caseEnd();

// Split so neither the token (token-files-match-the-plan) nor the retired stem (session-terms) appears literally.
const TOKEN = ["he", "ir_session_id"].join("");
const CHECKER = path.join(ROOT, "bin", "lib", "check-migration-blocks.js");
const REGISTRY = path.join(ROOT, "bin", "lib", "check-migration-blocks", "retired-tokens.txt");
const BOUNDARY_CASES = [
  { name: "plain", ident: TOKEN, detected: true },
  { name: "underscore-prefixed", ident: `foo_${TOKEN}`, detected: true },
  { name: "underscore-suffixed", ident: `${TOKEN}_v2`, detected: true },
  { name: "alpha-glued-before", ident: `t${TOKEN}`, detected: false },
  { name: "alnum-glued-both-sides", ident: `the${TOKEN}x`, detected: false },
  { name: "digit-glued-after", ident: `${TOKEN}2`, detected: false },
];

function scanFixture(caseName, ident) {
  const dir = path.join(NEUTRAL, `boundary-${caseName}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "sample.js"), `const value = ${ident};\n`);
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  const done = spawnSync(process.execPath, [CHECKER, "--retired-tokens-from", REGISTRY, "--all", dir],
    { cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  if (done.error) throw new Error(`check-migration-blocks.js did not run: ${done.error.message}`);
  return { code: done.status, stdout: done.stdout || "", show: `rc=${done.status} stdout=${done.stdout} stderr=${done.stderr}` };
}

caseBegin("token-boundary-rejects-alnum-only", "bin/lib/check-migration-blocks/retired-tokens.txt");
for (const c of BOUNDARY_CASES) {
  test(`the real registry ${c.detected ? "detects" : "ignores"} the ${c.name} form`, () => {
    const r = scanFixture(c.name, c.ident);
    const hit = new RegExp(`^sample\\.js:1: error: retired token .* of migration ${MIGRATION_ID} `, "m");
    if (c.detected) {
      assert.strictEqual(r.code, 1, r.show);
      assert.ok(hit.test(r.stdout), `the error must name ${MIGRATION_ID}: ${r.show}`);
    } else {
      assert.strictEqual(r.code, 0, r.show);
      assert.ok(!r.stdout.includes(MIGRATION_ID), `no ${MIGRATION_ID} finding expected: ${r.show}`);
    }
  });
}
caseEnd();
