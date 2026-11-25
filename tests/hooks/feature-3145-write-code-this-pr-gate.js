"use strict";
// tests/hooks/feature-3145-write-code-this-pr-gate.js
// Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/record-step-verdict/this-pr-open.js
// Tags: TL2, hooks, workflow-state, write-code, worktree-notes, this-pr, gate, regression-3145, scope:issue-specific, pwsh-not-required
// #3145 T4: write_code completes on sentinel / advance / mark only when notes are absent or every
// this-pr finding is settled; open -> code 2 kind this-pr-open (keys + three exits, nothing written),
// untrusted notes path -> this-pr-open-degraded; reset is not judged. Calls run in a child process
// because the notes path comes from its cwd (plan S3/S4).
// TL3 gap: a live /write-code MARK_STEP and `next-step --advance` from a real tool cwd are not run.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const F = require("../lib/this-pr-notes-fixture");

F.setup("t3145-wc");
const GATES = ["sentinel", "advance", "mark"];
let n = 0;
const sidFor = (tag) => `s-3145-wc-${tag}-${++n}`;

// fixture(tag, build) -> { repo, sid, notes }: session cwd is the linked worktree.
function fixture(tag, build) {
  const repo = F.makeRepo(tag);
  const sid = sidFor(tag);
  F.seedState(sid, repo.wt);
  const notes = build ? build(repo) : null;
  return { repo, sid, notes };
}

// The refusal shape, plus nothing written.
function assertRefused(fx, r, before, kind) {
  assert.ok(!r.error, `driver: ${r.error}`);
  assert.strictEqual(r.res.ok, false, `ok: ${JSON.stringify(r.res)}`);
  assert.strictEqual(r.res.code, 2, "code");
  assert.strictEqual(r.res.kind, kind, "kind");
  assert.strictEqual(F.eventCount(fx.sid), before, "event count unchanged");
  assert.notStrictEqual(F.stepStatus(fx.sid, "write_code"), "complete", "write_code not complete");
}

function assertPassed(fx, r) {
  assert.ok(!r.error, `driver: ${r.error}`);
  assert.strictEqual(r.res.ok, true, `ok: ${JSON.stringify(r.res)}`);
  assert.strictEqual(F.stepStatus(fx.sid, "write_code"), "complete", "write_code complete");
}

const UNFIXED = "Parser drops the trailing marker";

caseBegin("open this-pr-unfixed entry refuses on every gate with key and exits", "hooks/workflow-state/record-step-verdict.js");
test("T4: an unfixed this-pr entry refuses write_code completion on sentinel / advance / mark", () => {
  for (const gate of GATES) {
    const fx = fixture(`unfixed-${gate}`, (repo) => F.writeNotes(repo.wt, { BugsFound: [F.entry(UNFIXED, { loc: "src/a.js:1", base: repo.base })] }));
    const k = F.key("BugsFound", UNFIXED);
    const before = F.eventCount(fx.sid);
    const r = F.drive(fx.repo.wt, "gate", fx.sid, gate);
    assertRefused(fx, r, before, "this-pr-open");
    const m = r.res.message;
    assert.match(m, /this-pr findings are unsettled \(1\) in /, `${gate}: first line`);
    assert.ok(m.includes(`[${k}] this-pr-unfixed`), `${gate}: key line: ${m}`);
    assert.ok(m.includes(`key=${k} fixed`), `${gate}: exit (1) dispose fixed: ${m}`);
    assert.ok(/rescope /.test(m) && m.includes(`/issue-create --finding-key ${k}`), `${gate}: exit (2) rescope + issue-create: ${m}`);
    assert.ok(m.includes(`echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=${k} `), `${gate}: exit (3) sentinel: ${m}`);
  }
});
caseEnd();

caseBegin("every open reason is listed with its key", "hooks/workflow-state/record-step-verdict/this-pr-open.js");
test("T4: checkWriteCodeThisPr lists this-pr-unfixed, fixed-unverified and rescoped-unfiled", () => {
  const FIXED = "Cache key ignores the locale";
  const RESC = "Retry loop never backs off";
  const fx = fixture("reasons", (repo) => F.writeNotes(repo.wt, {
    BugsFound: [
      F.entry(UNFIXED, { base: repo.base }),
      F.entry(FIXED, { loc: "src/b.js:1", base: repo.base, terminal: "<!-- disposed: fixed -->" }),
    ],
    RelatedTasks: [F.entry(RESC, { scope: "other", rescoped: true })],
  }));
  const r = F.drive(fx.repo.wt, "check", fx.sid);
  assert.ok(!r.error, `driver: ${r.error}`);
  assert.ok(r.res && r.res.kind === "this-pr-open", `kind: ${JSON.stringify(r.res)}`);
  const m = r.res.message;
  assert.match(m, /unsettled \(3\)/, "count");
  assert.ok(m.includes(`[${F.key("BugsFound", UNFIXED)}] this-pr-unfixed`), m);
  assert.ok(m.includes(`[${F.key("BugsFound", FIXED)}] fixed-unverified`), m);
  assert.ok(m.includes(`[${F.key("RelatedTasks", RESC)}] rescoped-unfiled`), m);
});
caseEnd();

caseBegin("notes absent passes", "hooks/workflow-state/record-step-verdict.js");
test("T4: without WORKTREE_NOTES.md write_code completes on every gate", () => {
  for (const gate of GATES) {
    const fx = fixture(`absent-${gate}`);
    assertPassed(fx, F.drive(fx.repo.wt, "gate", fx.sid, gate));
  }
});
caseEnd();

caseBegin("every entry settled passes", "hooks/workflow-state/record-step-verdict.js");
test("T4: fixed with a changed loc, user-accepted, rescoped+promoted and other-scope entries all pass", () => {
  for (const gate of GATES) {
    const fx = fixture(`settled-${gate}`, (repo) => {
      fs.writeFileSync(path.join(repo.wt, "src", "a.js"), "module.exports = 10;\n");
      return F.writeNotes(repo.wt, {
        BugsFound: [
          F.entry("Fixed in a.js", { loc: "src/a.js:1", base: repo.base, terminal: "<!-- disposed: fixed -->" }),
          F.entry("Accepted by the user", { base: repo.base, terminal: "<!-- user-accepted: left as is -->" }),
        ],
        RelatedTasks: [
          F.entry("Moved to its own issue", { scope: "other", rescoped: true, terminal: "<!-- promoted: #9001 -->" }),
          F.entry("Unrelated follow-up", { scope: "other" }),
        ],
      });
    });
    assertPassed(fx, F.drive(fx.repo.wt, "gate", fx.sid, gate));
  }
});
caseEnd();

caseBegin("untrusted notes path refuses as degraded", "hooks/workflow-state/record-step-verdict/this-pr-open.js");
test("T4: unreadable notes, unresolved repo and cwd-mismatch refuse with this-pr-open-degraded", () => {
  const variants = {
    "notes unreadable (a directory)": (repo) => { fs.mkdirSync(path.join(repo.wt, "WORKTREE_NOTES.md")); return repo.wt; },
    "repo unresolved (non-git cwd)": (repo) => { F.writeNotes(repo.wt, { BugsFound: [F.entry(UNFIXED)] }); return repo.plain; },
    "cwd is the main repo, not the session worktree": (repo) => { F.writeNotes(repo.wt, { BugsFound: [F.entry(UNFIXED)] }); return repo.main; },
  };
  for (const [label, prep] of Object.entries(variants)) {
    for (const gate of GATES) {
      const fx = fixture(`degraded-${gate}`);
      const cwd = prep(fx.repo);
      const before = F.eventCount(fx.sid);
      const r = F.drive(cwd, "gate", fx.sid, gate);
      assert.doesNotThrow(() => assertRefused(fx, r, before, "this-pr-open-degraded"), `${label} / ${gate}: ${JSON.stringify(r)}`);
    }
  }
});
caseEnd();

caseBegin("reset gate is not judged", "hooks/workflow-state/record-step-verdict.js");
test("T4: the reset gate completes write_code even with an open this-pr entry", () => {
  const fx = fixture("reset", (repo) => F.writeNotes(repo.wt, { BugsFound: [F.entry(UNFIXED)] }));
  const r = F.drive(fx.repo.wt, "gate", fx.sid, "reset");
  assert.ok(!r.error, `driver: ${r.error}`);
  assert.ok(!/^this-pr-open/.test(String(r.res.kind || "")), `kind: ${JSON.stringify(r.res)}`);
  assert.strictEqual(r.res.ok, true, `ok: ${JSON.stringify(r.res)}`);
});
caseEnd();

caseBegin("recorded-verdict gate is not judged", "hooks/workflow-state/record-step-verdict.js");
test("T4: the recorded-verdict gate is outside THIS_PR_GATES and completes write_code with an open this-pr entry", () => {
  const { THIS_PR_GATES } = require(path.join(F.ROOT, "hooks", "workflow-state", "record-step-verdict", "this-pr-open.js"));
  assert.ok(!THIS_PR_GATES.includes("recorded-verdict"), `THIS_PR_GATES: ${THIS_PR_GATES}`);
  const fx = fixture("recorded-verdict", (repo) => F.writeNotes(repo.wt, { BugsFound: [F.entry(UNFIXED, { base: repo.base })] }));
  const r = F.drive(fx.repo.wt, "gate", fx.sid, "recorded-verdict");
  assert.ok(!r.error, `driver: ${r.error}`);
  assert.ok(!/^this-pr-open/.test(String(r.res.kind || "")), `kind: ${JSON.stringify(r.res)}`);
  assert.strictEqual(r.res.ok, true, `ok: ${JSON.stringify(r.res)}`);
  assert.strictEqual(F.stepStatus(fx.sid, "write_code"), "complete", "write_code complete");
});
caseEnd();

caseBegin("checkWriteCodeThisPr returns null when nothing is open", "hooks/workflow-state/record-step-verdict/this-pr-open.js");
test("T4: checkWriteCodeThisPr is null for absent notes and for other-scope only notes", () => {
  const absent = fixture("unit-absent");
  const r1 = F.drive(absent.repo.wt, "check", absent.sid);
  assert.ok(!r1.error, `driver: ${r1.error}`);
  assert.strictEqual(r1.res, null, "absent");
  const other = fixture("unit-other", (repo) => F.writeNotes(repo.wt, { BugsFound: [F.entry("Elsewhere", { scope: "other" })] }));
  const r2 = F.drive(other.repo.wt, "check", other.sid);
  assert.ok(!r2.error, `driver: ${r2.error}`);
  assert.strictEqual(r2.res, null, "other only");
});
caseEnd();
