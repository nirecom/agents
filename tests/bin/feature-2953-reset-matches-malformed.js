"use strict";
// Tests: bin/repo-settings, bin/migrate-needs, bin/lib/migrate-needs.js
// Tags: TL2, bin, migrate, repo-settings, scope:issue-specific
// #2953 — the MALFORMED=1 judgement of bin/migrate-needs and the --reset-malformed target of
// bin/repo-settings agree on every .agents.json shape; write() keeps refusing only unreadable files.
// TL3 gap: a real GitHub / GitLab remote; here the repo has no origin and nothing is pushed.
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
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rs2953-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
const MIGRATE_NEEDS = path.join(CHECKOUT, "bin", "migrate-needs");
const REPO_SETTINGS = path.join(CHECKOUT, "bin", "repo-settings");

const TESTS_OK = { dir: "tests", categorization: "flat", testHarness: "off", caseMarker: "off" };
const DONE = { tracker: "done", issues: "done", tests: "done" };

let seq = 0;
// repo(settings) — fresh git repo; settings = raw text or an object, written as .agents.json.
function repo(settings) {
  seq += 1;
  const d = path.join(TMP, `r${seq}`);
  fs.mkdirSync(d, { recursive: true });
  gitInit(d);
  fs.writeFileSync(path.join(d, "README"), "fixture\n");
  fs.writeFileSync(path.join(d, ".agents.json"), typeof settings === "string" ? settings : `${JSON.stringify(settings, null, 2)}\n`);
  return d;
}

function run(script, args, cwd) {
  const r = cp.spawnSync(process.execPath, [script, ...args], { cwd, encoding: "utf8", timeout: 60000 });
  return { rc: r.status, out: String(r.stdout || ""), err: String(r.stderr || "") };
}
function malformedOf(d) {
  const r = run(MIGRATE_NEEDS, ["--root", d], d);
  const m = /^MALFORMED=(.*)$/m.exec(r.out);
  assert.ok(m, `MALFORMED line is printed: ${r.out}${r.err}`);
  return m[1];
}
const reset = (d) => run(REPO_SETTINGS, ["--root", d, "--reset-malformed"], d);
const file = (d) => path.join(d, ".agents.json");
const backup = (d) => path.join(d, ".agents.json.malformed");
const bytes = (settings) => (typeof settings === "string" ? settings : `${JSON.stringify(settings, null, 2)}\n`);

// want "1": reset accepts it; want "0": reset leaves it alone.
const ROWS = [
  { id: "not JSON", settings: "{ not json\n", want: "1" },
  { id: "JSON array", settings: "[]\n", want: "1" },
  { id: "JSON null", settings: "null\n", want: "1" },
  { id: "JSON string", settings: "\"x\"\n", want: "1" },
  { id: "JSON number", settings: "42\n", want: "1" },
  { id: "version string \"1\"", settings: { version: "1" }, want: "1" },
  { id: "version 1.5", settings: { version: 1.5 }, want: "1" },
  { id: "version 0", settings: { version: 0 }, want: "1" },
  { id: "version -1", settings: { version: -1 }, want: "1" },
  { id: "version null", settings: { version: null }, want: "1" },
  { id: "tests section invalid", settings: { tests: { categorization: "bogus" } }, want: "1" },
  { id: "migrate section invalid", settings: { migrate: { tracker: "no" } }, want: "1" },
  { id: "version 2 (unsupported)", settings: { version: 2 }, want: "0" },
  { id: "version 2 over invalid tests", settings: { version: 2, tests: "x" }, want: "0" },
  { id: "valid object", settings: { version: 1, tests: TESTS_OK, migrate: DONE }, want: "0" },
  { id: "empty object", settings: {}, want: "0" },
];

caseBegin("RM-reset-matches-malformed", "bin/repo-settings");
test("RM-reset-matches-malformed: --reset-malformed acts exactly where migrate-needs reports MALFORMED=1", () => {
  for (const row of ROWS) {
    const d = repo(row.settings);
    assert.equal(malformedOf(d), row.want, `${row.id}: MALFORMED before reset`);
    const r = reset(d);
    assert.equal(r.rc, 0, `${row.id}: reset rc ${r.err}`);
    if (row.want === "1") {
      assert.equal(fs.readFileSync(backup(d), "utf8"), bytes(row.settings), `${row.id}: backup holds the original bytes`);
      assert.equal(fs.readFileSync(file(d), "utf8"), "{}\n", `${row.id}: file reset to {}`);
    } else {
      assert.equal(fs.existsSync(backup(d)), false, `${row.id}: no backup`);
      assert.equal(fs.readFileSync(file(d), "utf8"), bytes(row.settings), `${row.id}: file untouched`);
    }
  }
});
caseEnd();

caseBegin("RM-reset-clears-malformed", "bin/lib/migrate-needs.js");
test("RM-reset-clears-malformed: after a reset migrate-needs reports MALFORMED=0, and a second reset changes nothing", () => {
  for (const row of ROWS.filter((r) => r.want === "1")) {
    const d = repo(row.settings);
    assert.equal(reset(d).rc, 0, `${row.id}: first reset`);
    assert.equal(malformedOf(d), "0", `${row.id}: MALFORMED after reset`);
    const saved = fs.readFileSync(backup(d), "utf8");
    assert.equal(reset(d).rc, 0, `${row.id}: second reset`);
    assert.equal(fs.readFileSync(file(d), "utf8"), "{}\n", `${row.id}: file still {}`);
    assert.equal(fs.readFileSync(backup(d), "utf8"), saved, `${row.id}: backup not overwritten by the second reset`);
  }
});
caseEnd();

caseBegin("RM-reset-names-section", "bin/repo-settings");
test("RM-reset-names-section: the reset message names the backup file and the invalid part", () => {
  const rows = [
    { settings: { tests: { categorization: "bogus" } }, part: /has an invalid tests section: tests\./ },
    { settings: { migrate: { tracker: "no" } }, part: /has an invalid migrate section: migrate\./ },
    { settings: { version: "1" }, part: /has an invalid tests and migrate section: version:/ },
    { settings: { tests: { categorization: "bogus" }, migrate: { tracker: "no" } }, part: /has an invalid tests and migrate section: tests\./ },
  ];
  for (const { settings, part } of rows) {
    const d = repo(settings);
    const r = reset(d);
    assert.equal(r.rc, 0, r.err);
    assert.match(r.err, /\.agents\.json\.malformed/, "names the backup");
    assert.match(r.err, part, "names the invalid part");
  }
});
caseEnd();

// write() keeps its file-level refusal (#2953): only an unreadable file is refused up front, so a
// section-level malformed file is still repairable by writing the section.
caseBegin("RM-write-not-regressed", "bin/repo-settings");
test("RM-write-not-regressed: write repairs a bad tests section and refuses a bad version without touching the file", () => {
  const badTests = repo({ tests: { categorization: "bogus" }, migrate: DONE });
  const w = run(REPO_SETTINGS, ["--root", badTests, "--write-tests", JSON.stringify(TESTS_OK)], badTests);
  assert.equal(w.rc, 0, `--write-tests over a bad tests section: ${w.err}`);
  assert.deepEqual(JSON.parse(fs.readFileSync(file(badTests), "utf8")).tests, TESTS_OK);
  assert.equal(malformedOf(badTests), "0", "repaired by the write");

  const badTests2 = repo({ tests: { categorization: "bogus" } });
  const m = run(REPO_SETTINGS, ["--root", badTests2, "--set-migrate", "tracker"], badTests2);
  assert.equal(m.rc, 0, `--set-migrate beside a bad tests section: ${m.err}`);
  assert.equal(JSON.parse(fs.readFileSync(file(badTests2), "utf8")).migrate.tracker, "done");

  const badVersion = repo({ version: "1", tests: TESTS_OK });
  const before = fs.readFileSync(file(badVersion), "utf8");
  const v = run(REPO_SETTINGS, ["--root", badVersion, "--write-tests", JSON.stringify(TESTS_OK)], badVersion);
  assert.equal(v.rc, 1, `--write-tests on a bad version: ${v.err}`);
  assert.equal(fs.readFileSync(file(badVersion), "utf8"), before, "file untouched");

  const notJson = repo("{ not json\n");
  const n = run(REPO_SETTINGS, ["--root", notJson, "--write-tests", JSON.stringify(TESTS_OK)], notJson);
  assert.equal(n.rc, 1, "unreadable file still refused");
  assert.match(n.err, /--reset-malformed/, "points at the repair");
});
caseEnd();
