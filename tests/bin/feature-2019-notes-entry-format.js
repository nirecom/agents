"use strict";
// tests/bin/feature-2019-notes-entry-format.js
// Tests: hooks/lib/worktree-notes-sections.js, bin/worktree-notes-append.js
// Tags: TL2, bin, worktree-notes, entry-format, severity, pr-scope, instance, marker-order, legacy-format, table-driven, scope:issue-specific, pwsh-not-required
// #2019 S2: the fixed marker order severity -> instance -> loc -> test-failure -> pr-scope ->
// handoff-rejected -> terminal (promoted | disposed), composed only by composeEntryMarkers; the
// append CLI requires --severity and --pr-scope in all three triage sections, validates --instance,
// and refuses --user-acknowledged. Legacy entries are read high/low/none/no-marker -> HIGH/LOW/
// not-defect/MEDIUM with pr-scope other.
// TL3 gap: none — the CLI and the parser are pure file I/O.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2019e-"));
after(() => { restore(); fs.rmSync(SCRATCH, { recursive: true, force: true }); });

const ROOT = path.resolve(__dirname, "..", "..");
const S = require(path.join(ROOT, "hooks", "lib", "worktree-notes-sections.js"));
const APPEND = path.join(ROOT, "bin", "worktree-notes-append.js");
let seq = 0;

// notesFile(text) -> absolute WORKTREE_NOTES.md path in its own dir.
function notesFile(text) {
  seq += 1;
  const dir = path.join(SCRATCH, `n${seq}`);
  fs.mkdirSync(dir);
  const p = path.join(dir, "WORKTREE_NOTES.md");
  if (text !== undefined) fs.writeFileSync(p, text);
  return p;
}
function append(notesPath, args) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [APPEND, "--notes-path", notesPath, ...args], { env, cwd: SCRATCH, encoding: "utf8", timeout: 30000 });
  return { status: r.status, stderr: String(r.stderr || "") };
}
const firstEntry = (text, section) => S.scanSection(text, section).entries[0];

caseBegin("compose-fixed-order", "hooks/lib/worktree-notes-sections.js");
test("compose-fixed-order: every optional marker in the canonical order", () => {
  const ROWS = [
    ["all markers", { severity: "medium", instance: "a.js:3 returns null", loc: "a.js:3", testFailure: true, prScope: "other" },
      " <!-- severity: medium --> <!-- instance: a.js:3 returns null --> <!-- loc: a.js:3 --> <!-- test-failure --> <!-- pr-scope: other -->"],
    ["severity and scope only", { severity: "low", prScope: "this-pr" }, " <!-- severity: low --> <!-- pr-scope: this-pr -->"],
    ["not-defect", { severity: "not-defect", prScope: "other" }, " <!-- severity: not-defect --> <!-- pr-scope: other -->"],
    ["high with loc", { severity: "high", loc: "b.sh", prScope: "other" }, " <!-- severity: high --> <!-- loc: b.sh --> <!-- pr-scope: other -->"],
  ];
  for (const [name, input, want] of ROWS) assert.strictEqual(S.composeEntryMarkers(input), want, name);
});
caseEnd();

caseBegin("round-trip-new-markers", "hooks/lib/worktree-notes-sections.js");
test("round-trip-new-markers: compose then scan returns every field", () => {
  const ROWS = [
    { severity: "high", instance: "x fails on CRLF", loc: "hooks/x.js:10", testFailure: true, prScope: "other" },
    { severity: "medium", prScope: "this-pr" },
    { severity: "low", loc: "bin/y", prScope: "other" },
    { severity: "not-defect", prScope: "this-pr" },
  ];
  for (const input of ROWS) {
    const text = `# Worktree Notes\n\n## BugsFound\n- Title here${S.composeEntryMarkers(input)}\n`;
    const e = firstEntry(text, "BugsFound");
    const tag = JSON.stringify(input);
    assert.strictEqual(e.body, "Title here", `${tag}: body`);
    assert.strictEqual(e.severity, input.severity, `${tag}: severity`);
    assert.strictEqual(e.instance || null, input.instance || null, `${tag}: instance`);
    assert.strictEqual(e.loc || null, input.loc || null, `${tag}: loc`);
    assert.strictEqual(Boolean(e.testFailure), Boolean(input.testFailure), `${tag}: testFailure`);
    assert.strictEqual(e.prScope, input.prScope, `${tag}: prScope`);
    assert.ok(!e.handoffRejected, `${tag}: no handoff-rejected`);
    assert.ok(!e.disposed, `${tag}: not disposed`);
  }
});
caseEnd();

caseBegin("scan-terminal-and-handoff-markers", "hooks/lib/worktree-notes-sections.js");
test("scan-terminal-and-handoff-markers: handoff-rejected, disposed, promoted", () => {
  const base = "- T <!-- severity: medium --> <!-- instance: i --> <!-- test-failure --> <!-- pr-scope: other -->";
  const text = [
    "## BugsFound",
    `${base} <!-- handoff-rejected -->`,
    `${base} <!-- handoff-rejected --> <!-- disposed: known-limits -->`,
    `${base} <!-- promoted: #42 -->`,
    "",
  ].join("\n");
  const [a, b, c] = S.scanSection(text, "BugsFound").entries;
  assert.strictEqual(a.handoffRejected, true, "handoff-rejected parsed");
  assert.ok(!a.disposed, "no terminal marker");
  assert.strictEqual(b.disposed, "known-limits", "disposed kind parsed");
  assert.strictEqual(b.handoffRejected, true, "handoff-rejected kept before the terminal marker");
  assert.strictEqual(c.promotedNumber, 42, "promoted parsed");
  assert.strictEqual(c.severity, "medium", "severity survives a terminal marker");
  for (const e of [a, b, c]) assert.strictEqual(e.body, "T", "body stripped of every marker");
});
caseEnd();

caseBegin("legacy-format-reading", "hooks/lib/worktree-notes-sections.js");
test("legacy-format-reading: high / low / none / no marker", () => {
  const ROWS = [
    ["legacy high", "- L <!-- severity: high -->", "high"],
    ["legacy high + ack + promoted", "- L <!-- severity: high --> <!-- user-acknowledged: true --> <!-- promoted: #7 -->", "high"],
    ["legacy low", "- L <!-- severity: low -->", "low"],
    ["legacy none", "- L <!-- severity: none -->", "not-defect"],
    ["no marker", "- L", "medium"],
    ["ack only", "- L <!-- user-acknowledged: false -->", "medium"],
  ];
  for (const [name, line, want] of ROWS) {
    const e = firstEntry(`## RelatedTasks\n${line}\n`, "RelatedTasks");
    assert.strictEqual(e.severity, want, `${name}: severity`);
    assert.strictEqual(e.prScope, "other", `${name}: pr-scope other`);
    assert.ok(!e.instance, `${name}: no instance`);
    assert.ok(!e.testFailure, `${name}: not a test failure`);
    assert.strictEqual(e.body, "L", `${name}: body`);
  }
});
caseEnd();

caseBegin("cli-writes-new-format", "bin/worktree-notes-append.js");
test("cli-writes-new-format: all three triage sections", () => {
  for (const section of ["BugsFound", "RelatedTasks", "NextTasks"]) {
    const p = notesFile();
    const r = append(p, ["--section", section, "--title", "Find X", "--severity", "medium", "--pr-scope", "other", "--instance", "X fails on Y", "--loc", "bin/x.js:4", "--test-failure"]);
    assert.strictEqual(r.status, 0, `${section}: exit 0 (${r.stderr})`);
    const line = fs.readFileSync(p, "utf8").split(/\r?\n/).find((l) => l.startsWith("- "));
    assert.strictEqual(line, "- Find X <!-- severity: medium --> <!-- instance: X fails on Y --> <!-- loc: bin/x.js:4 --> <!-- test-failure --> <!-- pr-scope: other -->", `${section}: line`);
  }
  const p = notesFile();
  assert.strictEqual(append(p, ["--section", "BugsFound", "--title", "Min", "--severity", "not-defect", "--pr-scope", "this-pr"]).status, 0, "minimal flags");
  assert.ok(fs.readFileSync(p, "utf8").includes("- Min <!-- severity: not-defect --> <!-- pr-scope: this-pr -->"), "minimal line");
});
caseEnd();

caseBegin("cli-rejects-bad-input", "bin/worktree-notes-append.js");
test("cli-rejects-bad-input: exit 2 and nothing written", () => {
  const ok = ["--title", "T", "--severity", "low", "--pr-scope", "other"];
  const ROWS = [
    ["missing --severity on RelatedTasks", ["--section", "RelatedTasks", "--title", "T", "--pr-scope", "other"]],
    ["missing --pr-scope", ["--section", "NextTasks", "--title", "T", "--severity", "low"]],
    ["unknown severity", ["--section", "BugsFound", "--title", "T", "--severity", "none", "--pr-scope", "other"]],
    ["unknown pr-scope", ["--section", "BugsFound", "--title", "T", "--severity", "low", "--pr-scope", "mine"]],
    ["empty --instance", ["--section", "BugsFound", ...ok, "--instance", ""]],
    ["--instance with marker syntax", ["--section", "BugsFound", ...ok, "--instance", "a --> b"]],
    ["--instance with <!--", ["--section", "BugsFound", ...ok, "--instance", "a <!-- b"]],
    ["--instance with newline", ["--section", "BugsFound", ...ok, "--instance", "a\nb"]],
    ["--test-failure without --instance", ["--section", "BugsFound", ...ok, "--test-failure"]],
    ["--user-acknowledged retired", ["--section", "BugsFound", ...ok, "--user-acknowledged", "true"]],
  ];
  for (const [name, args] of ROWS) {
    const p = notesFile();
    const r = append(p, args);
    assert.strictEqual(r.status, 2, `${name}: exit 2 (${r.stderr})`);
    assert.ok(!fs.existsSync(p), `${name}: nothing written`);
  }
  const r = append(notesFile(), ["--section", "BugsFound", ...ok, "--user-acknowledged", "false"]);
  assert.ok(/user-acknowledged/.test(r.stderr), "the --user-acknowledged refusal names the retired flag (migration hint)");
});
caseEnd();
