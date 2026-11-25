"use strict";
// tests/bin/feature-3145-triage-scope.js
// Tests: bin/worktree-notes-triage.js, bin/worktree-notes-triage/scope.js
// Tags: worktree-notes, triage, cli, subprocess, this-pr, open-this-pr, check, rescope, key-ref, scope:issue-specific, TL2
// #3145: the triage CLI gains open-this-pr / check / rescope / unrescope, accepts key=<8hex> refs,
// and drops the known-limits dispose kind. Every case drives the real CLI in a child process on a
// real linked-worktree fixture (tests/lib/this-pr-notes-fixture.js).
// TL3 gap: preflight calling `check --session` from a live release run is not driven here;
// tests/skills/feature-3145-preflight-this-pr.sh covers the script on fixtures.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const F = require("../lib/this-pr-notes-fixture");

const TMP = F.setup("t3145-scope");
const BIN = path.join(F.ROOT, "bin", "worktree-notes-triage.js");
const fwd = (p) => p.replace(/\\/g, "/");

function triage(args, cwd) {
  const r = spawnSync(process.execPath, [BIN].concat(args), { cwd: cwd || TMP, encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env) });
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "", all: `${r.stdout || ""}${r.stderr || ""}` };
}
const read = (p) => fs.readFileSync(p, "utf8");
const openOf = (notes) => JSON.parse(triage(["open-this-pr", fwd(notes)]).stdout);

caseBegin("open-this-pr-schema-and-exit", "bin/worktree-notes-triage/scope.js");
test("open-this-pr prints {state, open, reason}; exit 0 for ok/absent, 1 for error", () => {
  const r = F.makeRepo("schema");
  const notes = F.writeNotes(r.wt, { BugsFound: [F.entry("open one", { base: r.base }), F.entry("other one", { scope: "other" })] });
  const ok = triage(["open-this-pr", fwd(notes)]);
  assert.strictEqual(ok.status, 0, ok.all);
  const j = JSON.parse(ok.stdout);
  assert.strictEqual(j.state, "ok", "state");
  assert.ok("reason" in j, "reason field present");
  assert.strictEqual(j.open.length, 1, "only the this-pr entry is open");
  assert.deepStrictEqual(Object.keys(j.open[0]).sort(), ["body", "detail", "key", "lineNumber", "reason", "section"], "open element schema");
  assert.deepStrictEqual([j.open[0].key, j.open[0].lineNumber, j.open[0].reason], [F.key("BugsFound", "open one"), 4, "this-pr-unfixed"], "open element");

  const absent = triage(["open-this-pr", fwd(path.join(r.plain, "WORKTREE_NOTES.md"))]);
  assert.strictEqual(absent.status, 0, absent.all);
  assert.deepStrictEqual([JSON.parse(absent.stdout).state, JSON.parse(absent.stdout).open], ["absent", []], "absent");

  const errDir = path.join(TMP, "err-notes");
  fs.mkdirSync(path.join(errDir, "WORKTREE_NOTES.md"), { recursive: true });
  const error = triage(["open-this-pr", fwd(path.join(errDir, "WORKTREE_NOTES.md"))]);
  assert.strictEqual(error.status, 1, error.all);
  assert.strictEqual(JSON.parse(error.stdout).state, "error", "unreadable notes -> error");
});
caseEnd();

caseBegin("check-path-exit-and-refusal-text", "bin/worktree-notes-triage/scope.js");
test("check <path>: 0 silent when settled or absent, 2 with the S3 refusal, 1 on error", () => {
  const r = F.makeRepo("check");
  const longBody = `long ${"x".repeat(95)}`;
  const notes = F.writeNotes(r.wt, {
    BugsFound: [F.entry("unfixed one", { base: r.base }), F.entry(longBody, { base: r.base })],
    RelatedTasks: [F.entry("moved one", { scope: "other", base: r.base, rescoped: true }), F.entry("done", { base: r.base, terminal: "<!-- user-accepted: by hand -->" })],
  });
  const res = triage(["check", fwd(notes)]);
  assert.strictEqual(res.status, 2, res.all);
  const first = res.all.split(/\r?\n/).find((l) => l.trim() !== "");
  assert.strictEqual(first, `this-pr findings are unsettled (3) in ${fwd(notes)}:`, "first line");
  const k1 = F.key("BugsFound", "unfixed one");
  const kr = F.key("RelatedTasks", "moved one");
  assert.ok(res.all.includes(`[${k1}] this-pr-unfixed: unfixed one`), "entry line");
  assert.ok(res.all.includes(`dispose ${fwd(notes)} key=${k1} fixed`), "exit (1) fix");
  assert.ok(res.all.includes(`rescope ${fwd(notes)} key=${k1}`), "exit (2) rescope");
  assert.ok(res.all.includes(`/issue-create --finding-key ${k1}`), "exit (2) file");
  assert.ok(res.all.includes(`echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=${k1} <reason>>>"`), "exit (3) accept");
  assert.ok(res.all.includes(`[${kr}] rescoped-unfiled: moved one`), "rescoped-unfiled line");
  assert.ok(res.all.includes(`annotate ${fwd(notes)} key=${kr} `), "exit (2b) annotate for rescoped-unfiled");
  assert.ok(res.all.includes(longBody.slice(0, 80)) && !res.all.includes(longBody), "body cut at 80 chars");
  assert.ok(!res.all.includes(F.key("RelatedTasks", "done")), "settled entry not listed");

  const settled = F.writeNotes(r.main, { BugsFound: [F.entry("done", { terminal: "<!-- user-accepted: ok -->" }), F.entry("o", { scope: "other" })] });
  const s = triage(["check", fwd(settled)]);
  assert.deepStrictEqual([s.status, s.all], [0, ""], "settled: exit 0, silent");
  const a = triage(["check", fwd(path.join(r.plain, "WORKTREE_NOTES.md"))]);
  assert.deepStrictEqual([a.status, a.all], [0, ""], "absent: exit 0, silent");
  const errDir = path.join(TMP, "check-err");
  fs.mkdirSync(path.join(errDir, "WORKTREE_NOTES.md"), { recursive: true });
  assert.strictEqual(triage(["check", fwd(path.join(errDir, "WORKTREE_NOTES.md"))]).status, 1, "error: exit 1");
});
caseEnd();

caseBegin("check-session-resolution", "bin/worktree-notes-triage/scope.js");
test("check --session reads the session worktree's notes; cwd outside it or no state is exit 1", () => {
  const r = F.makeRepo("session");
  F.seedState("sid-check", r.wt);
  const notes = F.writeNotes(r.wt, { BugsFound: [F.entry("session open", { base: r.base })] });
  const inWt = triage(["check", "--session", "sid-check"], r.wt);
  assert.strictEqual(inWt.status, 2, inWt.all);
  assert.ok(inWt.all.includes(F.key("BugsFound", "session open")), "lists the worktree entry");
  assert.ok(inWt.all.toLowerCase().includes(fwd(fs.realpathSync.native(notes)).toLowerCase()) || inWt.all.toLowerCase().includes(fwd(notes).toLowerCase()), "names the worktree notes");

  const outside = triage(["check", "--session", "sid-check"], r.main);
  assert.strictEqual(outside.status, 1, outside.all);
  assert.ok(/cwd-mismatch/.test(outside.all), `cwd-mismatch reported: ${outside.all}`);

  const noState = triage(["check", "--session", "sid-none"], r.wt);
  assert.strictEqual(noState.status, 1, `no state: ${noState.all}`);

  F.writeNotes(r.wt, { BugsFound: [F.entry("session done", { base: r.base, terminal: "<!-- user-accepted: ok -->" })] });
  const clear = triage(["check", "--session", "sid-check"], r.wt);
  assert.deepStrictEqual([clear.status, clear.all], [0, ""], "settled session: exit 0, silent");
});
caseEnd();

caseBegin("rescope-and-unrescope", "bin/worktree-notes-triage/scope.js");
test("rescope only this-pr-unfixed / fixed-unverified; unrescope only a rescoped entry", () => {
  const r = F.makeRepo("rescope");
  fs.writeFileSync(path.join(r.wt, "src", "a.js"), "module.exports = 10;\n");
  const fixed = "<!-- disposed: fixed -->";
  const notes = F.writeNotes(r.wt, {
    BugsFound: [
      F.entry("unfixed", { base: r.base }),
      F.entry("fixed elsewhere", { loc: "src/b.js", base: r.base, terminal: fixed }),
      F.entry("fixed here", { loc: "src/a.js", base: r.base, terminal: fixed }),
      F.entry("other", { scope: "other" }),
      F.entry("accepted", { base: r.base, terminal: "<!-- user-accepted: ok -->" }),
    ],
  });
  const ref = (b) => `key=${F.key("BugsFound", b)}`;
  for (const b of ["fixed here", "other", "accepted"]) {
    const before = read(notes);
    assert.notStrictEqual(triage(["rescope", fwd(notes), ref(b)]).status, 0, `${b}: rescope refused`);
    assert.strictEqual(read(notes), before, `${b}: file unchanged`);
  }
  assert.strictEqual(triage(["rescope", fwd(notes), ref("unfixed")]).status, 0, "unfixed rescoped");
  assert.strictEqual(triage(["rescope", fwd(notes), ref("fixed elsewhere")]).status, 0, "fixed-unverified rescoped");
  const lines = read(notes).split("\n");
  assert.ok(lines[3].includes("<!-- pr-scope: other -->") && lines[3].includes("<!-- rescoped-from: this-pr -->"), lines[3]);
  assert.ok(lines[4].includes("<!-- rescoped-from: this-pr -->") && !lines[4].includes("disposed: fixed"), `fixed dropped: ${lines[4]}`);
  const reasons = openOf(notes).open.map((o) => [o.body, o.reason]);
  assert.deepStrictEqual(reasons, [["unfixed", "rescoped-unfiled"], ["fixed elsewhere", "rescoped-unfiled"]], "rescoped entries stay open until filed");

  const before = read(notes);
  assert.notStrictEqual(triage(["rescope", fwd(notes), ref("unfixed")]).status, 0, "already rescoped: refused");
  assert.notStrictEqual(triage(["unrescope", fwd(notes), ref("other")]).status, 0, "unrescope of a never-rescoped entry: refused");
  assert.strictEqual(read(notes), before, "refusals leave the file unchanged");
  assert.strictEqual(triage(["unrescope", fwd(notes), ref("unfixed")]).status, 0, "unrescope");
  const back = read(notes).split("\n")[3];
  assert.ok(back.includes("<!-- pr-scope: this-pr -->") && !back.includes("rescoped-from"), back);
});
caseEnd();

caseBegin("key-ref-resolution", "bin/worktree-notes-triage.js");
test("key=<8hex>: one match acts, zero / duplicate / malformed exit 1 without writing", () => {
  const r = F.makeRepo("keyref");
  const notes = F.writeNotes(r.wt, {
    BugsFound: [F.entry("single", { scope: "other" }), F.entry("twin", { scope: "other" }), F.entry("twin", { scope: "other" })],
  });
  const before = read(notes);
  const single = F.key("BugsFound", "single");
  const missing = single === "deadbeef" ? "cafebabe" : "deadbeef";
  const BAD = [
    ["zero matches", ["annotate", fwd(notes), `key=${missing}`, "12"]],
    ["duplicate", ["annotate", fwd(notes), `key=${F.key("BugsFound", "twin")}`, "12"]],
    ["not hex", ["annotate", fwd(notes), "key=zzzzzzzz", "12"]],
    ["7 hex", ["annotate", fwd(notes), `key=${single.slice(0, 7)}`, "12"]],
    ["9 hex", ["annotate", fwd(notes), `key=${single}0`, "12"]],
    ["shell metacharacters", ["dispose", fwd(notes), `key=${single};rm`, "discard"]],
    ["dispose duplicate", ["dispose", fwd(notes), `key=${F.key("BugsFound", "twin")}`, "discard"]],
  ];
  for (const [name, args] of BAD) {
    assert.strictEqual(triage(args).status, 1, name);
    assert.strictEqual(read(notes), before, `${name}: file unchanged`);
  }
  assert.strictEqual(triage(["annotate", fwd(notes), `key=${single}`, "12"]).status, 0, "one match: annotate");
  assert.ok(read(notes).split("\n")[3].endsWith("<!-- promoted: #12 -->"), "annotated the keyed line");
});
caseEnd();

caseBegin("annotate-closes-rescoped-unfiled", "bin/worktree-notes-triage.js");
test("annotate on a rescoped-unfiled entry takes it out of the open set", () => {
  const r = F.makeRepo("annotate");
  const notes = F.writeNotes(r.wt, { NextTasks: [F.entry("moved", { scope: "other", base: r.base, rescoped: true })] });
  assert.deepStrictEqual(openOf(notes).open.map((o) => o.reason), ["rescoped-unfiled"], "open before");
  assert.strictEqual(triage(["annotate", fwd(notes), `key=${F.key("NextTasks", "moved")}`, "345"]).status, 0, "annotate");
  assert.deepStrictEqual(openOf(notes).open, [], "settled after filing");
  assert.strictEqual(triage(["check", fwd(notes)]).status, 0, "check passes");
});
caseEnd();

caseBegin("dispose-kind-refusals", "bin/worktree-notes-triage.js");
test("dispose refuses known-limits and user-accepted; the file is unchanged", () => {
  const r = F.makeRepo("kinds");
  const notes = F.writeNotes(r.wt, { BugsFound: [F.entry("o", { scope: "other" }), F.entry("t", { base: r.base })] });
  const before = read(notes);
  for (const line of ["4", "5"]) {
    for (const kind of ["known-limits", "user-accepted", "user-accepted: x"]) {
      assert.strictEqual(triage(["dispose", fwd(notes), line, kind]).status, 1, `line ${line} ${kind}`);
      assert.strictEqual(read(notes), before, `line ${line} ${kind}: unchanged`);
    }
  }
  assert.ok(!triage([]).all.includes("known-limits"), "usage no longer offers known-limits");
});
caseEnd();
