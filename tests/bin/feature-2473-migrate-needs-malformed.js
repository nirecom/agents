"use strict";
// Tests: bin/migrate-needs, bin/lib/migrate-needs.js
// Tags: TL2, bin, migrate, repo-settings, scope:issue-specific
// #2473 / #2953 — MALFORMED of bin/migrate-needs / collect(root): 1 when .agents.json is unparsable, not a
// JSON object, or fails the reader's validation (version, tests or migrate section), else 0; a newer
// version (unsupported) is 0. It is a pure fs read and adds no git, gh or glab start.
// Split from feature-2473-migrate-needs.js so each part stays under the per-test time cap.
// TL3 gap: a real GitHub / GitLab remote; here origin is a local bare repo that is never a forge.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cp = require("node:child_process");

const restore = isolate();
after(() => restore());

const CHECKOUT = path.resolve(__dirname, "..", "..");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "mn2473-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
const ORIG = { spawnSync: cp.spawnSync, execFileSync: cp.execFileSync, execSync: cp.execSync };

function git(dir, ...args) {
  const r = ORIG.spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout;
}
const commitAll = (d) => {
  git(d, "add", "-A");
  git(d, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--no-verify", "--allow-empty", "-m", "fixture");
};

const TESTS_OK = { dir: "tests", categorization: "flat", testHarness: "off", caseMarker: "off" };
const DONE = { tracker: "done", issues: "done", tests: "done" };

// repo(name, settings, origin) — committed repo; settings null = no file, a string = raw text.
function repo(name, settings, origin = "https://github.com/o/r.git") {
  const d = path.join(TMP, name);
  fs.mkdirSync(d, { recursive: true });
  gitInit(d);
  if (origin) git(d, "remote", "add", "origin", origin);
  fs.writeFileSync(path.join(d, "README"), "fixture\n");
  if (settings !== null) {
    fs.writeFileSync(path.join(d, ".agents.json"), typeof settings === "string" ? settings : `${JSON.stringify(settings, null, 2)}\n`);
  }
  commitAll(d);
  return d;
}

const CLI = path.join(CHECKOUT, "bin", "migrate-needs");
const LIB = path.join(CHECKOUT, "bin", "lib", "migrate-needs.js");

function cli(root) {
  const r = ORIG.spawnSync(process.execPath, [CLI, "--root", root], { cwd: root, encoding: "utf8", timeout: 60000 });
  const kv = {};
  for (const line of String(r.stdout || "").split(/\r?\n/)) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line);
    if (m) kv[m[1]] = m[2];
  }
  const needed = String(kv.NEEDED || "").split(/[,\s]+/).filter(Boolean).map((s) => s.replace(/^migrate-/, ""));
  return { rc: r.status, kv, needed, text: `${r.stdout || ""}${r.stderr || ""}` };
}

// spy(fn) — every child process started while fn runs, by command name (git, gh, glab, ...).
function spy(fn) {
  const seen = [];
  const name = (c) => path.basename(String(c).trim().split(/\s+/)[0]).replace(/\.(exe|cmd)$/i, "");
  cp.spawnSync = (c, ...a) => { seen.push(name(c)); return ORIG.spawnSync(c, ...a); };
  cp.execFileSync = (c, ...a) => { seen.push(name(c)); return ORIG.execFileSync(c, ...a); };
  cp.execSync = (c, ...a) => { seen.push(name(c)); return ORIG.execSync(c, ...a); };
  try {
    return { value: fn(), seen };
  } finally {
    Object.assign(cp, ORIG);
  }
}

// tracked(name, settings) — origin's pushurl is a local bare repo and the branch tracks origin's copy.
function tracked(name, settings = { tests: TESTS_OK, migrate: DONE }) {
  const d = repo(name, settings);
  const bare = `${d}.git`;
  ORIG.spawnSync("git", ["init", "-q", "--bare", bare], { encoding: "utf8" });
  git(d, "config", "remote.origin.pushurl", bare);
  git(d, "push", "-q", "-u", "origin", "HEAD");
  return d;
}

// MALFORMED: 1 when .agents.json is unparsable, not an object, or fails the reader's validation in
// version / tests / migrate (#2953); else 0.
const MALFORMED_ROWS = [
  { id: "not JSON", settings: "{ not json\n", want: "1" },
  { id: "JSON array", settings: "[]\n", want: "1" },
  { id: "JSON null", settings: "null\n", want: "1" },
  { id: "JSON string", settings: "\"x\"\n", want: "1" },
  { id: "JSON number", settings: "42\n", want: "1" },
  { id: "absent", settings: null, want: "0" },
  { id: "valid object", settings: { tests: TESTS_OK, migrate: DONE }, want: "0" },
  // A newer schema version is unsupported, not malformed: never offered for reset.
  { id: "version 2 object", settings: { version: 2 }, want: "0" },
  { id: "version 2 over an invalid tests value", settings: { version: 2, tests: "x" }, want: "0" },
  { id: "version 1 object", settings: { version: 1, tests: TESTS_OK, migrate: DONE }, want: "0" },
  { id: "empty object", settings: {}, want: "0" },
  { id: "version 1 alone", settings: { version: 1 }, want: "0" },
  // An invalid version fails the reader's validation (#2953).
  { id: "version string \"1\"", settings: { version: "1" }, want: "1" },
  { id: "version 1.5", settings: { version: 1.5 }, want: "1" },
  { id: "version 0", settings: { version: 0 }, want: "1" },
  { id: "version -1", settings: { version: -1 }, want: "1" },
  { id: "version null", settings: { version: null }, want: "1" },
  { id: "tests bogus categorization", settings: { tests: { categorization: "bogus" } }, want: "1" },
  { id: "tests is an array", settings: { tests: [] }, want: "1" },
  { id: "migrate invalid value", settings: { migrate: { tracker: "no" } }, want: "1" },
  { id: "migrate unknown key", settings: { migrate: { x: "done" } }, want: "1" },
];

caseBegin("MN-malformed-table", "bin/migrate-needs");
test("MN-malformed-table: MALFORMED through collect() and the bin/migrate-needs stdout", () => {
  const { collect } = require(LIB);
  MALFORMED_ROWS.forEach((row, i) => {
    const d = repo(`malformed-row-${i}`, row.settings);
    const r = cli(d);
    assert.equal(r.rc, 0, `${row.id}: rc ${r.text}`);
    assert.ok("MALFORMED" in r.kv, `${row.id}: MALFORMED line is printed: ${r.text}`);
    assert.equal(r.kv.MALFORMED, row.want, `${row.id}: CLI MALFORMED ${r.text}`);
    assert.equal(String(collect(d).malformed), row.want, `${row.id}: collect().malformed`);
  });
});
caseEnd();

caseBegin("MN-malformed-no-extra-process", "bin/lib/migrate-needs.js");
test("MN-malformed-no-extra-process: MALFORMED is a pure fs read and adds no git, gh or glab launch", () => {
  const { collect } = require(LIB);
  const valid = spy(() => collect(tracked("malformed-budget-valid")));
  assert.deepEqual(valid.seen, ["git"], `valid object, in sync: status only: ${JSON.stringify(valid.seen)}`);
  assert.equal(String(valid.value.malformed), "0");
  // Unparsable: every key is needed, so the host lookup adds one git remote get-url; nothing else.
  const bad = spy(() => collect(tracked("malformed-budget-bad", "{ not json\n")));
  assert.deepEqual(bad.seen, ["git", "git"], `malformed, in sync: status + host lookup only: ${JSON.stringify(bad.seen)}`);
  assert.equal(String(bad.value.malformed), "1");
  // Invalid version (#2953): judged by the same fs read, no extra process.
  const badVersion = spy(() => collect(tracked("malformed-budget-version", { version: "1" })));
  assert.deepEqual(badVersion.seen, ["git", "git"], `invalid version, in sync: status + host lookup only: ${JSON.stringify(badVersion.seen)}`);
  assert.equal(String(badVersion.value.malformed), "1");
});
caseEnd();
