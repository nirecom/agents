"use strict";
// tests/hooks/feature-3145-this-pr-accept-sentinel.js
// Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-mark/this-pr-accept-handler.js, hooks/workflow-mark.js, settings.json
// Tags: TL2, hooks, sentinel, workflow-mark, worktree-notes, this-pr, this-pr-finding-accepted, adversarial, regression-3145, scope:issue-specific, pwsh-not-required
// #3145 T5: `echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=<8hex> <reason>>>"` writes a
// user-accepted terminal only for a key that is open (fixed-unverified included); a LOOKSLIKE-only
// form, a settled or absent key, or an unresolvable notes path is UNAPPLIED with the file
// byte-identical. Handler calls run in a child process: the notes path comes from its cwd (plan S3).
// The ask-not-allow row lives here too; tests/install/feature-2280-settings-deny-anchor.sh owns AV1.
// TL3 gap: the Claude Code permission prompt for the ask rule is not exercised.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const F = require("../lib/this-pr-notes-fixture");

F.setup("t3145-acc");
const SP = () => require(path.join(F.ROOT, "hooks", "lib", "sentinel-patterns.js"));
const sentinel = (k, reason) => `echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=${k} ${reason}>>"`;
let n = 0;
const sidFor = (tag) => `s-3145-acc-${tag}-${++n}`;
const UNFIXED = "Parser drops the trailing marker";
const FIXED = "Cache key ignores the locale";
const OTHER = "Unrelated follow-up";

// fixture(tag) -> { repo, sid, notes, before }: one open unfixed, one fixed-unverified, one other.
function fixture(tag) {
  const repo = F.makeRepo(tag);
  const sid = sidFor(tag);
  F.seedState(sid, repo.wt);
  const notes = F.writeNotes(repo.wt, {
    BugsFound: [
      F.entry(UNFIXED, { loc: "src/a.js:1", base: repo.base }),
      F.entry(FIXED, { loc: "src/b.js:1", base: repo.base, terminal: "<!-- disposed: fixed -->" }),
      F.entry(OTHER, { scope: "other" }),
    ],
  });
  return { repo, sid, notes, before: fs.readFileSync(notes, "utf8") };
}
const lineOf = (text, body) => text.split("\n").find((l) => l.startsWith(`- ${body} `));

caseBegin("DQ regex accepts the well-formed sentinel and rejects malformed ones", "hooks/lib/sentinel-patterns.js");
test("T5: THIS_PR_FINDING_ACCEPTED_RE_DQ accept / reject table", () => {
  const M = SP();
  const re = M.THIS_PR_FINDING_ACCEPTED_RE_DQ;
  assert.ok(re instanceof RegExp, "THIS_PR_FINDING_ACCEPTED_RE_DQ is exported");
  const ok = sentinel("0a1b2c3d", "user accepts it");
  const m = re.exec(ok);
  assert.ok(m && m[1] === "0a1b2c3d" && m[2] === "user accepts it", "captures key and reason");
  assert.strictEqual(M.isSentinel(ok), true, "isSentinel");
  assert.strictEqual(M.isStrictSentinel(ok), true, "isStrictSentinel");
  const rejects = {
    "no payload": 'echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED>>"',
    "no reason": 'echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=0a1b2c3d>>"',
    "no key": 'echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: user accepts it>>"',
    "key 7 hex": sentinel("0a1b2c3", "r"),
    "key 9 hex": sentinel("0a1b2c3d4", "r"),
    "key uppercase": sentinel("0A1B2C3D", "r"),
    "key non-hex": sentinel("0a1b2c3g", "r"),
    "comment close in reason": sentinel("0a1b2c3d", "r --> x"),
    "dollar paren": sentinel("0a1b2c3d", "$(evil)"),
    "backtick": sentinel("0a1b2c3d", "`evil`"),
    "semicolon": sentinel("0a1b2c3d", "a; rm -f b"),
    "pipe": sentinel("0a1b2c3d", "a | cat"),
    "ampersand": sentinel("0a1b2c3d", "a & b"),
    "and-chain after": `${sentinel("0a1b2c3d", "r")} && rm -f /tmp/x`,
    "chain before": `rm -f /tmp/x && ${sentinel("0a1b2c3d", "r")}`,
  };
  for (const [label, cmd] of Object.entries(rejects)) {
    assert.strictEqual(re.test(cmd), false, `regex rejects: ${label}`);
    assert.strictEqual(M.isStrictSentinel(cmd), false, `isStrictSentinel rejects: ${label}`);
  }
});
caseEnd();

caseBegin("LOOKSLIKE-only form is UNAPPLIED and writes nothing", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: a LOOKSLIKE-only sentinel is handled as UNAPPLIED with format guidance", () => {
  const M = SP();
  const look = M.THIS_PR_FINDING_ACCEPTED_LOOKSLIKE || M.THIS_PR_FINDING_ACCEPTED_LOOKSLIKE_RE || M.LOOKSLIKE_THIS_PR_FINDING_ACCEPTED;
  assert.ok(look instanceof RegExp, "a LOOKSLIKE regex is exported");
  for (const cmd of ['echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: 0a1b2c3d no key prefix>>"', sentinel("0a1b2c3d", "a; b")]) {
    assert.ok(look.test(cmd), `LOOKSLIKE matches: ${cmd}`);
    const fx = fixture("look");
    const r = F.drive(fx.repo.wt, "accept", fx.sid, cmd);
    assert.ok(!r.error, `driver: ${r.error}`);
    assert.strictEqual(r.handled, true, `handled: ${cmd}`);
    assert.ok(r.unapplied.length > 0 && r.unapplied.join("\n").includes("key="), `format guidance: ${JSON.stringify(r)}`);
    assert.strictEqual(fs.readFileSync(fx.notes, "utf8"), fx.before, "notes byte-identical");
  }
});
caseEnd();

caseBegin("an unrelated command is not claimed by the handler", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: the handler returns false for a command that is not this sentinel", () => {
  const fx = fixture("other-cmd");
  const r = F.drive(fx.repo.wt, "accept", fx.sid, 'echo "<<WORKFLOW_ABORT_ACCEPTED: r>>"');
  assert.ok(!r.error, `driver: ${r.error}`);
  assert.strictEqual(r.handled, false, "not handled");
  assert.strictEqual(fs.readFileSync(fx.notes, "utf8"), fx.before, "notes byte-identical");
});
caseEnd();

caseBegin("an open key gets user-accepted and write_code then completes", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: accepting the unfixed and the fixed-unverified keys settles both; the T4 gate passes", () => {
  const fx = fixture("open");
  for (const body of [UNFIXED, FIXED]) {
    const r = F.drive(fx.repo.wt, "accept", fx.sid, sentinel(F.key("BugsFound", body), "user keeps it as is"));
    assert.ok(!r.error, `driver: ${r.error}`);
    assert.strictEqual(r.handled, true, `handled: ${body}`);
    assert.deepStrictEqual(r.unapplied, [], `applied: ${body}`);
    const line = lineOf(fs.readFileSync(fx.notes, "utf8"), body);
    assert.ok(line && line.endsWith(" <!-- user-accepted: user keeps it as is -->"), `terminal: ${line}`);
    assert.ok(!line.includes("disposed: fixed"), `fixed terminal replaced: ${line}`);
  }
  assert.strictEqual(lineOf(fs.readFileSync(fx.notes, "utf8"), OTHER), lineOf(fx.before, OTHER), "other entry untouched");
  const g = F.drive(fx.repo.wt, "gate", fx.sid, "sentinel");
  assert.ok(!g.error && g.res.ok === true, `write_code completes: ${JSON.stringify(g)}`);
});
caseEnd();

caseBegin("settled key, absent key and resolve error are UNAPPLIED with the file unchanged", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: nothing is written unless the key is open in the trusted notes", () => {
  const variants = {
    "settled (other-scope) key": (fx) => [fx.repo.wt, F.key("BugsFound", OTHER)],
    "absent key": (fx) => [fx.repo.wt, "deadbeef"],
    "cwd-mismatch (main repo cwd)": (fx) => [fx.repo.main, F.key("BugsFound", UNFIXED)],
    "repo unresolved (non-git cwd)": (fx) => [fx.repo.plain, F.key("BugsFound", UNFIXED)],
  };
  for (const [label, pick] of Object.entries(variants)) {
    const fx = fixture("noop");
    const [cwd, k] = pick(fx);
    const r = F.drive(cwd, "accept", fx.sid, sentinel(k, "user ok"));
    assert.ok(!r.error, `${label}: driver: ${r.error}`);
    assert.strictEqual(r.handled, true, `${label}: handled`);
    assert.ok(r.unapplied.length > 0, `${label}: UNAPPLIED: ${JSON.stringify(r)}`);
    assert.strictEqual(fs.readFileSync(fx.notes, "utf8"), fx.before, `${label}: notes byte-identical`);
  }
});
caseEnd();

caseBegin("missing sessionId and a reason empty after sanitizing are UNAPPLIED with the file unchanged", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: no session id, or a reason that sanitizes to nothing, writes no marker", () => {
  const k = F.key("BugsFound", UNFIXED);
  const noSid = fixture("nosid");
  const r1 = F.drive(noSid.repo.wt, "accept", "", sentinel(k, "user keeps it"));
  assert.ok(!r1.error && r1.handled === true, `no sid: ${JSON.stringify(r1)}`);
  assert.ok(r1.unapplied.join("\n").includes("session_id"), `no sid: UNAPPLIED: ${JSON.stringify(r1)}`);
  assert.deepStrictEqual(r1.msgs, [], "no sid: no applied message");
  assert.strictEqual(fs.readFileSync(noSid.notes, "utf8"), noSid.before, "no sid: notes byte-identical");
  for (const reason of ["<<<", "< < <", "<< <<"]) {
    const fx = fixture("empty-reason");
    const r = F.drive(fx.repo.wt, "accept", fx.sid, sentinel(k, reason));
    assert.ok(!r.error && r.handled === true, `${reason}: ${JSON.stringify(r)}`);
    assert.ok(r.unapplied.length > 0, `${reason}: UNAPPLIED: ${JSON.stringify(r)}`);
    assert.deepStrictEqual(r.msgs, [], `${reason}: no applied message`);
    assert.strictEqual(fs.readFileSync(fx.notes, "utf8"), fx.before, `${reason}: notes byte-identical`);
  }
  // The writer's own guard (accept() maps it to UNAPPLIED): an all-'<' / newline reason leaves the text as is.
  const S = require(path.join(F.ROOT, "hooks", "lib", "worktree-notes-sections.js"));
  const fx = fixture("empty-unit");
  const hit = require(path.join(F.ROOT, "bin", "lib", "this-pr-open.js")).readOpenThisPr(fx.notes).open.find((o) => o.key === k);
  assert.ok(hit, "the unfixed key is open");
  assert.notStrictEqual(S.markEntryUserAccepted(fx.before, hit.lineNumber, "real reason"), fx.before, "a real reason edits the line");
  for (const reason of ["<<<", " <> ", "\n<\n", ""]) {
    assert.strictEqual(S.markEntryUserAccepted(fx.before, hit.lineNumber, reason), fx.before, `${JSON.stringify(reason)}: text unchanged`);
  }
});
caseEnd();

caseBegin("a second accept of the same key is UNAPPLIED and adds no marker", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: re-sending the sentinel for a settled key, same or different reason, leaves the notes byte-identical", () => {
  const fx = fixture("again");
  const k = F.key("BugsFound", UNFIXED);
  const first = F.drive(fx.repo.wt, "accept", fx.sid, sentinel(k, "first reason"));
  assert.ok(!first.error && first.handled === true, `first accept: ${JSON.stringify(first)}`);
  assert.deepStrictEqual(first.unapplied, [], "first accept applied");
  const settled = fs.readFileSync(fx.notes, "utf8");
  for (const reason of ["first reason", "a different reason"]) {
    const r = F.drive(fx.repo.wt, "accept", fx.sid, sentinel(k, reason));
    assert.ok(!r.error, `${reason}: driver: ${r.error}`);
    assert.strictEqual(r.handled, true, `${reason}: handled`);
    assert.ok(r.unapplied.length > 0, `${reason}: UNAPPLIED: ${JSON.stringify(r)}`);
    const after = fs.readFileSync(fx.notes, "utf8");
    assert.strictEqual(after, settled, `${reason}: notes byte-identical`);
    assert.strictEqual((lineOf(after, UNFIXED).match(/<!-- user-accepted:/g) || []).length, 1, `${reason}: one user-accepted marker`);
  }
});
caseEnd();

caseBegin("a rescoped-unfiled key is settled by the sentinel", "hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: accepting a rescoped-unfiled key writes user-accepted and the write_code gate then passes", () => {
  const repo = F.makeRepo("rescoped");
  const sid = sidFor("rescoped");
  F.seedState(sid, repo.wt);
  const MOVED = "Moved to a follow-up issue";
  const notes = F.writeNotes(repo.wt, { BugsFound: [F.entry(MOVED, { scope: "other", base: repo.base, rescoped: true })] });
  const r = F.drive(repo.wt, "accept", sid, sentinel(F.key("BugsFound", MOVED), "no issue needed"));
  assert.ok(!r.error && r.handled === true, `accept: ${JSON.stringify(r)}`);
  assert.deepStrictEqual(r.unapplied, [], "applied");
  const line = lineOf(fs.readFileSync(notes, "utf8"), MOVED);
  assert.ok(line && line.endsWith(" <!-- user-accepted: no issue needed -->"), `terminal: ${line}`);
  assert.ok(line.includes("<!-- rescoped-from: this-pr -->"), `rescoped-from kept: ${line}`);
  const g = F.drive(repo.wt, "gate", sid, "sentinel");
  assert.ok(!g.error && g.res.ok === true, `write_code completes: ${JSON.stringify(g)}`);
});
caseEnd();

caseBegin("adversarial reasons never inject markers or lines","hooks/workflow-mark/this-pr-accept-handler.js");
test("T5: a reason carrying <!-- or a newline lands as one sanitized marker on the same line", () => {
  const reasons = {
    "comment open": "ok <!-- pr-scope: other",
    "newline": "ok\n## BugsFound\n- injected entry",
  };
  for (const [label, reason] of Object.entries(reasons)) {
    const fx = fixture("adv");
    const r = F.drive(fx.repo.wt, "accept", fx.sid, sentinel(F.key("BugsFound", UNFIXED), reason));
    assert.ok(!r.error, `${label}: driver: ${r.error}`);
    const after = fs.readFileSync(fx.notes, "utf8");
    assert.strictEqual(after.split("\n").length, fx.before.split("\n").length, `${label}: line count unchanged`);
    assert.ok(!after.split("\n").some((l) => l.startsWith("- injected")), `${label}: no injected entry`);
    const line = lineOf(after, UNFIXED) || "";
    const opens = (line.match(/<!--/g) || []).length;
    const was = (lineOf(fx.before, UNFIXED).match(/<!--/g) || []).length;
    assert.ok(opens === was || opens === was + 1, `${label}: at most one marker added: ${line}`);
    assert.ok(!/<!-- pr-scope: other/.test(line), `${label}: pr-scope not overridden: ${line}`);
  }
});
caseEnd();

caseBegin("the handler runs before markStepHandler", "hooks/workflow-mark.js");
test("T5: workflow-mark.js registers this-pr-accept-handler in HANDLERS before markStepHandler", () => {
  const src = fs.readFileSync(path.join(F.ROOT, "hooks", "workflow-mark.js"), "utf8");
  const req = /const (\w+) = require\("\.\/workflow-mark\/this-pr-accept-handler"\)/.exec(src);
  assert.ok(req, "this-pr-accept-handler is required");
  const list = /const HANDLERS = \[([\s\S]*?)\];/.exec(src);
  assert.ok(list, "HANDLERS array found");
  const names = list[1].replace(/\/\/.*$/gm, "").split(/[\s,]+/).filter(Boolean);
  const at = names.indexOf(req[1]);
  assert.ok(at !== -1, `${req[1]} is in HANDLERS`);
  assert.ok(at < names.indexOf("markStepHandler"), "before markStepHandler");
});
caseEnd();

caseBegin("settings.json asks for the sentinel and never allows it", "settings.json");
test("T5: the ask list carries the rule; the allow list does not", () => {
  const rule = 'Bash(echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: *>>")';
  const perms = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8")).permissions || {};
  assert.ok((perms.ask || []).includes(rule), "ask carries the rule");
  assert.ok(!(perms.allow || []).some((r) => r.includes("WORKFLOW_THIS_PR_FINDING_ACCEPTED")), "allow does not");
});
caseEnd();
