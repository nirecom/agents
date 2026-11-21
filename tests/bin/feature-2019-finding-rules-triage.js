"use strict";
// tests/bin/feature-2019-finding-rules-triage.js
// Tests: bin/lib/finding-rules.js, bin/worktree-notes-triage.js
// Tags: TL2, bin, worktree-notes, triage, finding-rules, classify, handoff, dispose, final-list, overflow, fail-closed, table-driven, scope:issue-specific, pwsh-not-required
// #2019 S3: classify() turns every rule-table row into auto-high / final-list / dispose-in-pr /
// discard / test-failure-handoff; `list` groups the undisposed entries (finalList sorted by loc,
// loc-less last, 16 + overflow, `{}` when nothing is pending); `handoff` runs the #2488 receiver
// contract (accepted / missing / failed / rejected); `dispose` writes the terminal marker once.
// Assumption: the receiver path is overridable through FINDING_HANDOFF_BIN and is run as `node <bin> <json-path>`.
// TL3 gap: the real #2488 receiver (it does not exist yet; only the I/O contract is pinned here).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2019r-"));
after(() => { restore(); fs.rmSync(SCRATCH, { recursive: true, force: true }); });

const ROOT = path.resolve(__dirname, "..", "..");
const RULES = require(path.join(ROOT, "bin", "lib", "finding-rules.js"));
const TRIAGE = path.join(ROOT, "bin", "worktree-notes-triage.js");
const CAPTURE = path.join(SCRATCH, "handoff-input.json");
const MISSING_BIN = path.join(SCRATCH, "no-such-handoff-bin");
let seq = 0;

// fakeBin(stdout, exitCode) -> a node receiver that copies its input file to CAPTURE.
function fakeBin(stdout, exitCode) {
  seq += 1;
  const p = path.join(SCRATCH, `handoff-${seq}.js`);
  fs.writeFileSync(p, `const fs=require("fs");fs.copyFileSync(process.argv[2],${JSON.stringify(CAPTURE)});process.stdout.write(${JSON.stringify(stdout)});process.exit(${exitCode});\n`);
  return p;
}
function notesFile(lines) {
  seq += 1;
  const dir = path.join(SCRATCH, `n${seq}`);
  fs.mkdirSync(dir);
  const p = path.join(dir, "WORKTREE_NOTES.md");
  fs.writeFileSync(p, `# Worktree Notes\n\n${lines.join("\n")}\n`);
  return p;
}
function triage(args, handoffBin) {
  const env = Object.assign({}, process.env, { FINDING_HANDOFF_BIN: handoffBin || MISSING_BIN });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [TRIAGE, ...args], { env, cwd: SCRATCH, encoding: "utf8", timeout: 30000 });
  return { status: r.status, stdout: String(r.stdout || ""), stderr: String(r.stderr || "") };
}
const list = (p, bin) => JSON.parse(triage(["list", p], bin).stdout);
const keyOf = (section, body) => crypto.createHash("sha256").update(`${section}\n${body}`).digest("hex").slice(0, 8);
const line = (body, m) => `- ${body} <!-- severity: ${m.sev} -->${m.inst ? ` <!-- instance: ${m.inst} -->` : ""}${m.loc ? ` <!-- loc: ${m.loc} -->` : ""}${m.tf ? " <!-- test-failure -->" : ""} <!-- pr-scope: ${m.scope || "other"} -->${m.rej ? " <!-- handoff-rejected -->" : ""}${m.tail || ""}`;
const lineNo = (p, body) => fs.readFileSync(p, "utf8").split(/\r?\n/).findIndex((l) => l.startsWith(`- ${body} `)) + 1;
const rawLine = (p, body) => fs.readFileSync(p, "utf8").split(/\r?\n/).find((l) => l.startsWith(`- ${body} `));

caseBegin("classify-rule-table", "bin/lib/finding-rules.js");
test("classify-rule-table: every row of the intent's rule table", () => {
  // [name, entry, handoffAvailable, want]
  const ROWS = [
    ["HIGH other", { severity: "high", prScope: "other" }, false, "auto-high"],
    ["HIGH this-pr, no instance", { severity: "high", prScope: "this-pr" }, false, "auto-high"],
    ["MEDIUM + instance, other", { severity: "medium", instance: "i", prScope: "other" }, false, "final-list"],
    ["MEDIUM + instance, this-pr", { severity: "medium", instance: "i", prScope: "this-pr" }, false, "final-list"],
    ["MEDIUM no instance, this-pr", { severity: "medium", prScope: "this-pr" }, false, "dispose-in-pr"],
    ["MEDIUM no instance, other", { severity: "medium", prScope: "other" }, false, "final-list"],
    ["LOW this-pr", { severity: "low", prScope: "this-pr" }, false, "dispose-in-pr"],
    ["LOW other", { severity: "low", prScope: "other" }, false, "discard"],
    ["not-defect this-pr", { severity: "not-defect", prScope: "this-pr" }, false, "dispose-in-pr"],
    ["not-defect other", { severity: "not-defect", prScope: "other" }, false, "discard"],
    ["test-failure + receiver", { severity: "medium", instance: "i", testFailure: true, prScope: "other" }, true, "test-failure-handoff"],
    ["test-failure HIGH + receiver", { severity: "high", instance: "i", testFailure: true, prScope: "other" }, true, "test-failure-handoff"],
    ["test-failure, no receiver", { severity: "medium", instance: "i", testFailure: true, prScope: "other" }, false, "final-list"],
    ["test-failure + receiver but rejected", { severity: "low", instance: "i", testFailure: true, handoffRejected: true, prScope: "other" }, true, "discard"],
  ];
  for (const [name, entry, handoffAvailable, want] of ROWS) {
    assert.strictEqual(RULES.classify(entry, { handoffAvailable }), want, name);
  }
});
caseEnd();

caseBegin("list-groups-and-shape", "bin/worktree-notes-triage.js");
test("list-groups-and-shape: six groups, element fields, terminal entries excluded", () => {
  const p = notesFile([
    "## BugsFound",
    line("High one", { sev: "high", loc: "a.js:1" }),
    line("Fix here", { sev: "medium", scope: "this-pr" }),
    line("Drop me", { sev: "low" }),
    line("Done", { sev: "medium", tail: " <!-- disposed: fixed -->" }),
    line("Filed", { sev: "medium", tail: " <!-- promoted: #5 -->" }),
    "",
    "## RelatedTasks",
    line("Pick me", { sev: "medium", inst: "fails on X", loc: "b.js:2" }),
    "- Weird one <!-- severity: weird --> <!-- pr-scope: other -->",
    "",
    "## NextTasks",
    line("Flaky", { sev: "medium", inst: "t1 red", tf: true }),
  ]);
  const r = triage(["list", p]);
  assert.strictEqual(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  for (const k of ["autoHigh", "finalList", "overflow", "disposeInPr", "discard", "testFailureHandoff"]) assert.ok(Array.isArray(out[k]), `${k} is an array`);
  const bodies = (k) => out[k].map((e) => e.body);
  assert.deepStrictEqual(bodies("autoHigh"), ["High one"], "autoHigh");
  assert.deepStrictEqual(bodies("disposeInPr"), ["Fix here"], "disposeInPr");
  assert.deepStrictEqual(bodies("discard"), ["Drop me"], "discard");
  assert.deepStrictEqual(bodies("testFailureHandoff"), [], "no receiver -> testFailureHandoff empty");
  assert.deepStrictEqual(bodies("finalList").sort(), ["Flaky", "Pick me", "Weird one"], "finalList (unknown severity reads MEDIUM, no instance, other)");
  const all = Object.values(out).flat().map((e) => e.body);
  assert.ok(!all.includes("Done") && !all.includes("Filed"), "disposed and promoted entries are excluded");
  const pick = out.finalList.find((e) => e.body === "Pick me");
  assert.strictEqual(pick.section, "RelatedTasks", "section");
  assert.strictEqual(pick.key, keyOf("RelatedTasks", "Pick me"), "key = sha256(section\\nbody)[0..8]");
  assert.strictEqual(pick.severity, "medium", "severity");
  assert.strictEqual(pick.instance, "fails on X", "instance");
  assert.strictEqual(pick.loc, "b.js:2", "loc");
  assert.strictEqual(pick.lineNumber, lineNo(p, "Pick me"), "lineNumber");
  assert.strictEqual(out.finalList.find((e) => e.body === "Weird one").severity, "medium", "unknown severity -> medium");
});
caseEnd();

caseBegin("list-final-list-cap-and-order", "bin/worktree-notes-triage.js");
test("list-final-list-cap-and-order: 16 vs 17 entries, loc order, loc-less last", () => {
  const mk = (n) => {
    const lines = ["## RelatedTasks"];
    for (let i = 0; i < n; i += 1) lines.push(line(`E${String(i).padStart(2, "0")}`, { sev: "medium", loc: i === 0 ? null : `f${String(n - i).padStart(2, "0")}.js` }));
    return notesFile(lines);
  };
  const o16 = list(mk(16));
  assert.strictEqual(o16.finalList.length, 16, "16 entries all fit");
  assert.strictEqual((o16.overflow || []).length, 0, "16 entries: no overflow");
  assert.strictEqual(o16.finalList[15].body, "E00", "the loc-less entry is last");
  const locs = o16.finalList.slice(0, 15).map((e) => e.loc);
  assert.deepStrictEqual(locs, locs.slice().sort(), "sorted by loc");
  const o17 = list(mk(17));
  assert.strictEqual(o17.finalList.length, 16, "17 entries: 16 in the list");
  assert.deepStrictEqual(o17.overflow.map((e) => e.body), ["E00"], "17 entries: the loc-less one overflows");
});
caseEnd();

caseBegin("list-empty-object", "bin/worktree-notes-triage.js");
test("list-empty-object: nothing pending prints {}", () => {
  const ROWS = [
    ["no entries", ["## BugsFound", "- (none)"]],
    ["only terminal entries", ["## BugsFound", line("A", { sev: "low", tail: " <!-- disposed: discard -->" }), line("B", { sev: "high", tail: " <!-- promoted: #9 -->" })]],
  ];
  for (const [name, lines] of ROWS) {
    const r = triage(["list", notesFile(lines)]);
    assert.strictEqual(r.status, 0, `${name}: exit 0`);
    assert.deepStrictEqual(JSON.parse(r.stdout), {}, `${name}: {}`);
  }
});
caseEnd();

caseBegin("handoff-contract", "bin/worktree-notes-triage.js");
test("handoff-contract: accepted / missing / failed / rejected", () => {
  const ok = fakeBin("handoff: accepted\n", 0);
  const entry = line("Red test", { sev: "medium", inst: "t2 red on win32", loc: "tests/x.sh", tf: true });
  const p0 = notesFile(["## BugsFound", entry]);
  assert.deepStrictEqual(list(p0, ok).testFailureHandoff.map((e) => e.body), ["Red test"], "receiver present -> testFailureHandoff");
  fs.rmSync(CAPTURE, { force: true });
  const r0 = triage(["handoff", p0, String(lineNo(p0, "Red test"))], ok);
  assert.strictEqual(r0.status, 0, `accepted: exit 0 (${r0.stderr})`);
  assert.ok(/<!-- disposed: handed-off -->$/.test(rawLine(p0, "Red test")), "accepted -> disposed: handed-off");
  const sent = JSON.parse(fs.readFileSync(CAPTURE, "utf8"));
  assert.strictEqual(sent.section, "BugsFound", "receiver gets section");
  assert.strictEqual(sent.body, "Red test", "receiver gets body");
  assert.strictEqual(sent.instance, "t2 red on win32", "receiver gets instance");
  assert.strictEqual(sent.loc, "tests/x.sh", "receiver gets loc");
  assert.deepStrictEqual(list(p0, ok), {}, "a handed-off entry leaves the list");

  // [name, bin, want result]
  const ROWS = [
    ["missing", MISSING_BIN, "missing"],
    ["non-zero exit", fakeBin("handoff: accepted\n", 3), "failed"],
    ["exit 0 without accepted line", fakeBin("ok\n", 0), "rejected"],
  ];
  for (const [name, bin, want] of ROWS) {
    const p = notesFile(["## BugsFound", entry]);
    const r = triage(["handoff", p, String(lineNo(p, "Red test"))], bin);
    assert.ok(new RegExp(`^handoff: ${want}$`, "m").test(r.stdout), `${name}: handoff: ${want} (${r.stdout})`);
    assert.ok(/^class: final-list$/m.test(r.stdout), `${name}: reclassified without the receiver`);
    const raw = rawLine(p, "Red test");
    assert.ok(raw.includes("<!-- handoff-rejected -->"), `${name}: handoff-rejected written`);
    assert.ok(!raw.includes("disposed:"), `${name}: not disposed`);
    const again = list(p, ok);
    assert.deepStrictEqual(again.testFailureHandoff, [], `${name}: next list keeps it off the handoff side`);
    assert.deepStrictEqual(again.finalList.map((e) => e.body), ["Red test"], `${name}: next list shows it on the rule-table side`);
  }
});
caseEnd();

caseBegin("dispose-terminal-marker", "bin/worktree-notes-triage.js");
test("dispose-terminal-marker: write once, re-run no-op, never on a promoted entry", () => {
  for (const kind of ["fixed", "known-limits", "discard"]) {
    const p = notesFile(["## BugsFound", line("D", { sev: "low", scope: "this-pr" })]);
    const n = String(lineNo(p, "D"));
    assert.strictEqual(triage(["dispose", p, n, kind]).status, 0, `${kind}: exit 0`);
    assert.ok(rawLine(p, "D").endsWith(` <!-- disposed: ${kind} -->`), `${kind}: terminal marker at the end`);
    const before = fs.readFileSync(p, "utf8");
    assert.strictEqual(triage(["dispose", p, n, kind]).status, 0, `${kind}: re-run exit 0`);
    assert.strictEqual(triage(["dispose", p, n, "discard"]).status, 0, `${kind}: another kind on a disposed entry exit 0`);
    assert.strictEqual(fs.readFileSync(p, "utf8"), before, `${kind}: re-run leaves the file byte-identical`);
  }
  const p = notesFile(["## BugsFound", line("P", { sev: "medium", tail: " <!-- promoted: #12 -->" })]);
  const before = fs.readFileSync(p, "utf8");
  assert.strictEqual(triage(["dispose", p, String(lineNo(p, "P")), "fixed"]).status, 0, "promoted: exit 0");
  assert.strictEqual(fs.readFileSync(p, "utf8"), before, "promoted entry is never disposed");
  const q = notesFile(["## BugsFound", line("Q", { sev: "low" })]);
  const qBefore = fs.readFileSync(q, "utf8");
  assert.notStrictEqual(triage(["dispose", q, String(lineNo(q, "Q")), "handed-off"]).status, 0, "handed-off is not a dispose kind");
  assert.notStrictEqual(triage(["dispose", q, String(lineNo(q, "Q")), "bogus"]).status, 0, "unknown kind refused");
  assert.strictEqual(fs.readFileSync(q, "utf8"), qBefore, "a refused dispose writes nothing");
});
caseEnd();
