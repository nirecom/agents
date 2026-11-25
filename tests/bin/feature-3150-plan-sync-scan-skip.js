"use strict";
// Tests: bin/plan-sync-scan-skip
// Tags: TL2, bin, plan-sync, scan-outbound, security, subprocess, cli, scope:issue-specific, settings-permissions, allow-list, breadcrumb
// #3150 T-E: `plan-sync-scan-skip <abs plan path> --reason <text>` records a one-shot, content-bound
// scan skip: the plan's blob id goes to plansync.scanSkipBlob and the reason to
// plansync.scanSkipReason in the plans repo's local git config, and one line naming the blob's
// first 8 hex digits is printed. A path that is not a sync target, is not a regular file, or a
// missing / short (< 3 chars) reason exits 1 and records nothing.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const restore = isolate();
delete process.env.CLAUDE_CODE_SESSION_ID;
const REPO = path.join(__dirname, "..", "..");
const CLI = path.join(REPO, "bin", "plan-sync-scan-skip");
const { isSyncTarget } = require(path.join(REPO, "hooks", "lib", "plan-sync", "allowlist.js"));
const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f3150-skip-")));
after(() => { fs.rmSync(TMP, { recursive: true, force: true }); restore(); });

const T = { timeout: 60000 };
const PLANS = path.join(TMP, "plans");
fs.mkdirSync(PLANS);
gitInit(PLANS);
const SID = "3150cccc-0001-4aaa-8bbb-000000000001";
const PLAN = path.join(PLANS, `${SID}-detail.md`);
const PLAN2 = path.join(PLANS, `${SID}-intent.md`);
const OUTSIDE = path.join(TMP, "elsewhere", `${SID}-detail.md`);
const NOT_TARGET = path.join(PLANS, "notes.md");
const DIR_PLAN = path.join(PLANS, `${SID}-outline.md`);
fs.mkdirSync(path.dirname(OUTSIDE));
fs.writeFileSync(OUTSIDE, "outside\n");
fs.writeFileSync(NOT_TARGET, "notes\n");
fs.mkdirSync(DIR_PLAN);

const git = (args, input) => spawnSync("git", ["-C", PLANS, ...args], { encoding: "utf8", input });
const cfg = (key) => git(["config", "--local", "--get-all", key]).stdout.split("\n").filter(Boolean);
const blobOf = (text) => git(["hash-object", "--no-filters", "--stdin"], text).stdout.trim();
function clear() {
  git(["config", "--local", "--unset-all", "plansync.scanSkipBlob"]);
  git(["config", "--local", "--unset-all", "plansync.scanSkipReason"]);
}

// run(args) -> { status, stdout, stderr }; WORKFLOW_PLANS_DIR is the fixture plans repo.
function run(args) {
  assert.ok(fs.existsSync(CLI), `CLI missing: ${path.relative(REPO, CLI)}`);
  const env = { ...process.env, WORKFLOW_PLANS_DIR: PLANS };
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: TMP, env, encoding: "utf8", timeout: 30000 });
  assert.ok(!r.error, `spawn error: ${r.error && r.error.message}`);
  return r;
}
// refused(r) — exit 1 from the CLI itself (not a module-load crash), nothing recorded.
function refused(r, label) {
  assert.strictEqual(r.status, 1, `${label}: exit 1 (stdout=${r.stdout} stderr=${r.stderr})`);
  assert.ok(!/Cannot find module|SyntaxError/.test(r.stderr), `${label}: the CLI ran (${r.stderr})`);
  assert.match(r.stderr, /plan-sync-scan-skip/, `${label}: the CLI names itself`);
  assert.deepStrictEqual(cfg("plansync.scanSkipBlob"), [], `${label}: no approval recorded`);
}

caseBegin("records-content-bound-approval", "bin/plan-sync-scan-skip");
test("fixture sanity: the plan is a sync target, the others are not", T, () => {
  assert.strictEqual(isSyncTarget(PLANS, PLAN), true);
  assert.strictEqual(isSyncTarget(PLANS, NOT_TARGET), false);
  assert.strictEqual(isSyncTarget(PLANS, OUTSIDE), false);
});
test("a target plan: blob id and reason land in the local config; one line with the blob prefix", T, () => {
  clear();
  fs.writeFileSync(PLAN, "plan body v1\n");
  const r = run([PLAN, "--reason", "scanner broken on this host"]);
  assert.strictEqual(r.status, 0, `exit 0 (stderr=${r.stderr})`);
  const blob = blobOf("plan body v1\n");
  assert.deepStrictEqual(cfg("plansync.scanSkipBlob"), [blob]);
  assert.deepStrictEqual(cfg("plansync.scanSkipReason"), ["scanner broken on this host"]);
  const lines = r.stdout.split("\n").filter(Boolean);
  assert.strictEqual(lines.length, 1, `one line: ${r.stdout}`);
  assert.ok(lines[0].includes(blob.slice(0, 8)), `blob prefix shown: ${lines[0]}`);
  assert.ok(!r.stdout.includes("plan body v1"), "the plan content is not echoed");
});
test("re-running after an edit replaces the approval (one value, the new blob)", T, () => {
  clear();
  fs.writeFileSync(PLAN, "plan body v1\n");
  assert.strictEqual(run([PLAN, "--reason", "first try"]).status, 0);
  fs.writeFileSync(PLAN, "plan body v2\n");
  assert.strictEqual(run([PLAN, "--reason", "second try"]).status, 0);
  assert.deepStrictEqual(cfg("plansync.scanSkipBlob"), [blobOf("plan body v2\n")]);
  assert.deepStrictEqual(cfg("plansync.scanSkipReason"), ["second try"]);
});
test("a reason of exactly 3 characters is accepted", T, () => {
  clear();
  fs.writeFileSync(PLAN, "plan body v3\n");
  const r = run([PLAN, "--reason", "abc"]);
  assert.strictEqual(r.status, 0, `exit 0 (stderr=${r.stderr})`);
  assert.deepStrictEqual(cfg("plansync.scanSkipBlob"), [blobOf("plan body v3\n")]);
});
caseEnd();

caseBegin("refuses-bad-input", "bin/plan-sync-scan-skip");
const REFUSALS = [
  ["a path in the plans dir that is not a sync target", () => [NOT_TARGET, "--reason", "valid reason"]],
  ["a target-shaped name outside the plans dir", () => [OUTSIDE, "--reason", "valid reason"]],
  ["a directory with a target name (not a regular file)", () => [DIR_PLAN, "--reason", "valid reason"]],
  ["a missing plan file", () => [path.join(PLANS, "3150cccc-0002-4aaa-8bbb-000000000001-intent.md"), "--reason", "valid reason"]],
  ["no --reason", () => [PLAN]],
  ["--reason with no value", () => [PLAN, "--reason"]],
  ["a reason shorter than 3 characters", () => [PLAN, "--reason", "ab"]],
  ["a blank reason", () => [PLAN, "--reason", "   "]],
  ["--reason given twice", () => [PLAN, "--reason", "abc", "--reason", "def"], /--reason given more than once/],
  ["an unknown option", () => [PLAN, "--force", "--reason", "abc"], /unknown argument: --force/],
  ["a second plan path", () => [PLAN, PLAN2, "--reason", "abc"], /unknown argument: /],
];
for (const [label, argsOf, why] of REFUSALS) {
  test(`exit 1: ${label}`, T, () => {
    clear();
    fs.writeFileSync(PLAN, "plan body\n");
    const r = run(argsOf());
    refused(r, label);
    if (why) assert.match(r.stderr, why, `${label}: the refusal names its reason`);
  });
}
test("exit 1: the approval cannot be stored (config.lock held) -> no success line", T, () => {
  clear();
  fs.writeFileSync(PLAN, "plan body lock\n");
  const lock = path.join(PLANS, ".git", "config.lock");
  fs.writeFileSync(lock, "");
  let r;
  try { r = run([PLAN, "--reason", "scanner broken on this host"]); } finally { fs.rmSync(lock, { force: true }); }
  refused(r, "config.lock");
  assert.match(r.stderr, /cannot record/, `stderr names the store failure: ${r.stderr}`);
  assert.strictEqual(r.stdout, "", "no success line");
});
caseEnd();

// The human check of a skip is the permission dialog: settings.json must ask on both path separators.
caseBegin("approval-asks-the-user", "bin/plan-sync-scan-skip");
test("settings.json asks before every plan-sync-scan-skip run and no allow row lets it through", T, () => {
  const perms = JSON.parse(fs.readFileSync(path.join(REPO, "settings.json"), "utf8")).permissions || {};
  const ask = perms.ask || [];
  for (const row of ["Bash(node *bin/plan-sync-scan-skip*)", "Bash(node *\\bin\\plan-sync-scan-skip*)"]) {
    assert.ok(ask.includes(row), `permissions.ask has ${row}`);
  }
  const blanket = new Set(["Bash", "Bash(*)", "Bash(node *)", "Bash(node:*)"]);
  const hits = (perms.allow || []).filter((r) => /plan-sync-scan-skip/.test(r) || blanket.has(r));
  assert.deepStrictEqual(hits, [], "no permissions.allow row matches the CLI");
});
test("bash-guard's auto-allow list has no plan-sync-scan-skip entry", T, () => {
  const text = fs.readFileSync(path.join(REPO, "install", "settings-allow-commands.txt"), "utf8");
  const entries = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  assert.ok(entries.length > 0, "the list was read");
  assert.deepStrictEqual(entries.filter((l) => /plan-sync-scan-skip/.test(l)), [], "no allow entry");
});
// globRe(row) -> the Bash(...) permission pattern as an anchored regex ("*" is any run of characters).
const globRe = (row) => new RegExp(`^${row.replace(/^Bash\(|\)$/g, "").split("*")
  .map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[\\s\\S]*")}$`);
const { scanLines } = require(path.join(REPO, "hooks", "show-plan-link", "scan-breadcrumb.js"));
for (const reason of ["scan-unavailable", "scan-timeout"]) {
  test(`the breadcrumb's skip command (${reason}) is caught by the ask row`, T, () => {
    const head = scanLines({ status: "failed", reason, findings: [] }, PLAN)[0];
    const prefix = `[plan-sync] ${reason} `;
    assert.ok(head.startsWith(prefix), head);
    const cmd = head.slice(prefix.length);
    assert.ok(cmd.includes("plan-sync-scan-skip") && cmd.startsWith("node "), cmd);
    assert.match(cmd, globRe("Bash(node *bin/plan-sync-scan-skip*)"), "the shown command meets the permission dialog");
  });
}
caseEnd();
