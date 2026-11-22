"use strict";
// bin/pm-instructions cases of tests/hooks/feature-3019-pm-instructions.js (#3019). No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const W8 = require("./world");

const { P, MD_ENV, CONTRACT, mark, byKey, fixtureMd, makeWorld, firstLine } = W8;
const brief = (r) => `code=${r.code} out=${JSON.stringify(r.out.slice(0, 600))} err=${JSON.stringify(r.err.slice(0, 300))}`;
const code = (r, want) => assert.strictEqual(r.code, want, brief(r));
const noPath = (r, p) => {
  const variants = [p, P.fwd(p), path.basename(p)];
  for (const v of variants) assert.ok(!r.err.includes(v), `stderr leaks the path (${v}): ${brief(r)}`);
  assert.ok(r.err.trim().length > 0, `no reason on stderr: ${brief(r)}`);
};

function setup(S, name) {
  const w = makeWorld(S, `cli-${name}`);
  const md = { [MD_ENV]: S.md("cli", fixtureMd()) };
  const sid = { pm: P.uuid(0x30190801), wf: P.uuid(0x30190802), bare: P.uuid(0x30190803) };
  const own = { c1: P.uuid(0x30190811), c2: P.uuid(0x30190812), c3: P.uuid(0x30190813), c4: P.uuid(0x30190814) };
  w.pm(sid.pm, P.pm({ tag: "PM-cliX", issues: [4800] }));
  w.pm(own.c1, P.pm({ tag: "PM-ck1", issues: [4601] }));
  w.pm(own.c2, P.pm({ tag: "PM-ck2", issues: [4602] }));
  w.pm(own.c3, P.pm({ tag: "PM-ck3", issues: [4600] }));
  w.pm(own.c4, P.pm({ tag: "PM-ck4", issues: [4603] }));
  w.field({ "o/r#4800": "PM-cliX", "o/r#4601": "PM-ck1", "o/r#4602": "PM-ck2", "o/r#4600": "PM-ck3", "o/r#4603": "PM-ck4" });
  w.plain(sid.wf);
  w.intent(sid.wf, ["#4601"]);
  w.plain(sid.bare);
  // ckpt(name, obj) -> a checkpoint file path; obj may be a raw string.
  const ckpt = (name, obj) => {
    const f = path.join(w.dir, `ckpt-${name}.json`);
    fs.writeFileSync(f, typeof obj === "string" ? obj : JSON.stringify(obj));
    return f;
  };
  return { w, md, sid, own, ckpt };
}

// The driver's input tokens were #4600 (a meta) and #4602; meta_select replaced #4600 by #4601..#4603 and
// closed_reopen_4602 removed #4602, so state.issues is [4601, 4603]; repo_map keeps stale positions.
const doneState = (issues) => ({ issues, repo_map: { 0: "stale/repo", 1: "stale/repo", 2: "stale/repo" }, path_decision: "A" });
const checkpointOf = (sessionId, issues, version) => ({ version: version === undefined ? 3 : version, session_id: sessionId, phase: "done", ask_id: null, state: doneState(issues) });

function argErrors(S) {
  const { w, md, sid, ckpt } = setup(S, "args");
  const f = ckpt("args", checkpointOf(sid.bare, [4601]));
  for (const [label, args] of [
    ["an unknown flag", ["--timing", "session-start", "--session", sid.wf, "--bogus"]],
    ["--issue together with --checkpoint", ["--timing", "session-start", "--session", sid.bare, "--issue", "#4601", "--checkpoint", f]],
    ["no --timing", ["--session", sid.wf]],
    ["a --timing value outside the contract", ["--timing", "whenever", "--session", sid.wf]],
  ]) {
    test(`cli-args: ${label} -> exit 2`, () => code(w.cli(args, md), 2));
  }
}

function inputs(S) {
  const { w, md, sid, own, ckpt } = setup(S, "inputs");
  test("cli-issue: --issue resolves an owner for a session without an intent", () => {
    const r = w.cli(["--timing", "session-start", "--session", sid.bare, "--issue", "#4601"], md);
    code(r, 0);
    assert.ok(r.out.includes("PM-ck1") && r.out.includes(own.c1), brief(r));
  });
  test("cli-issue: --issue may repeat; each issue's owner is listed", () => {
    const r = w.cli(["--timing", "session-start", "--session", sid.bare, "--issue", "#4601", "--issue", "#4603"], md);
    code(r, 0);
    for (const s of ["PM-ck1", "PM-ck4"]) assert.ok(r.out.includes(s), `${s}: ${brief(r)}`);
  });
  test("cli-session: no --session -> CLAUDE_CODE_SESSION_ID is the session", () => {
    const a = w.cli(["--timing", "session-start"], Object.assign({ CLAUDE_CODE_SESSION_ID: sid.wf }, md));
    const b = w.cli(["--timing", "session-start", "--session", sid.wf], md);
    code(a, 0);
    assert.ok(a.out.includes("PM-ck1"), brief(a));
    assert.strictEqual(a.out, b.out);
  });
  test("cli-checkpoint: only the owners of state.issues are injected, not of the driver's input tokens", () => {
    const before = w.ghLog().length;
    const r = w.cli(["--timing", "session-start", "--session", sid.bare, "--checkpoint", ckpt("done", checkpointOf(sid.bare, [4601, 4603]))], md);
    code(r, 0);
    for (const s of ["PM-ck1", own.c1, "PM-ck4", own.c4]) assert.ok(r.out.includes(s), `${s}: ${brief(r)}`);
    for (const s of ["PM-ck2", "PM-ck3"]) assert.ok(!r.out.includes(s), `${s} leaked: ${brief(r)}`);
    // The PM field is read for state.issues only: the driver's input tokens never reach the forge.
    const asked = w.ghLog().slice(before);
    for (const n of [4600, 4602]) assert.ok(!new RegExp(`number:\\s*${n}\\b`).test(asked), `#${n} was looked up: ${asked.slice(0, 600)}`);
  });
  test("cli-checkpoint: empty state.issues (Path C) -> empty stdout, exit 0", () => {
    const r = w.cli(["--timing", "session-start", "--session", sid.bare, "--checkpoint", ckpt("empty", checkpointOf(sid.bare, []))], md);
    code(r, 0);
    assert.strictEqual(r.out, "", brief(r));
  });
  test("cli-role-none: a session with no role -> empty stdout, exit 0", () => {
    const r = w.cli(["--timing", "session-start", "--session", sid.bare], md);
    code(r, 0);
    assert.strictEqual(r.out, "", brief(r));
  });
  test("cli-pm: a PM session gets the PM bundle", () => {
    const r = w.cli(["--timing", "session-start", "--session", sid.pm], md);
    code(r, 0);
    assert.strictEqual(firstLine(r.out), "[pm-instructions role=pm timing=session-start]", brief(r));
    assert.ok(r.out.includes(mark(byKey("pm", "session-start"))), brief(r));
  });
}

function failures(S) {
  const { w, md, sid, ckpt } = setup(S, "failures");
  const bad = [
    ["a checkpoint path that does not exist", () => path.join(w.dir, "ckpt-never-written.json")],
    ["a checkpoint that is not JSON", () => ckpt("broken", "{not json")],
    ["a checkpoint of another version", () => ckpt("v2", checkpointOf(sid.bare, [4601], 2))],
    ["state.issues that is not an array", () => ckpt("shape", Object.assign(checkpointOf(sid.bare, []), { state: { issues: "4601" } }))],
  ];
  for (const [label, file] of bad) {
    test(`cli-checkpoint-error: ${label} -> exit 1, stderr without the path`, () => {
      const f = file();
      const r = w.cli(["--timing", "session-start", "--session", sid.bare, "--checkpoint", f], md);
      code(r, 1);
      assert.strictEqual(r.out, "", brief(r));
      noPath(r, f);
    });
  }
  test("cli-md-error: the SSOT md absent -> exit 1, stderr without the path", () => {
    const f = S.md("cli-absent", null);
    const r = w.cli(["--timing", "session-start", "--session", sid.pm], { [MD_ENV]: f });
    code(r, 1);
    noPath(r, f);
  });
  test("cli-md-error: a contract heading missing -> exit 1", () => {
    const f = S.md("cli-missing", fixtureMd({ drop: { h2: "PM session" } }));
    code(w.cli(["--timing", "session-start", "--session", sid.pm], { [MD_ENV]: f }), 1);
  });
  test("cli-session-shape: a traversal-shaped --session never injects", () => {
    const r = w.cli(["--timing", "session-start", "--session", "../../etc/passwd"], md);
    assert.ok([0, 1, 2].includes(r.code), brief(r));
    assert.strictEqual(r.out, "", brief(r));
  });
}

// timings: a single timing key returns that H3 only, for the workflow role.
function timings(S) {
  const { w, md, sid } = setup(S, "timings");
  for (const key of ["before-companions", "after-final-report"]) {
    test(`cli-timing: --timing ${key} returns only that section`, () => {
      const r = w.cli(["--timing", key, "--session", sid.wf], md);
      code(r, 0);
      assert.strictEqual(firstLine(r.out), `[pm-instructions role=workflow timing=${key}]`, brief(r));
      for (const c of CONTRACT) {
        const want = c.recipient === "workflow" && c.timing === key;
        assert.strictEqual(r.out.includes(mark(c)), want, `${mark(c)} present=${!want}: ${brief(r)}`);
      }
      assert.ok(r.out.includes("PM-ck1"), brief(r));
    });
  }
}

// bareIssue (#2942): `--issue N` is the same request as `--issue #N`; a non-issue number stays exit 2.
function bareIssue(S) {
  const { w, md, sid, own } = setup(S, "bare");
  for (const [label, bare, hashed] of [["one issue", ["4601"], ["#4601"]], ["repeated issues", ["4601", "4603"], ["#4601", "#4603"]]]) {
    test(`cli-issue-bare: ${label} as bare N -> same exit 0 and stdout as #N`, () => {
      const args = (refs) => ["--timing", "before-companions", "--session", sid.bare].concat(...refs.map((x) => ["--issue", x]));
      const a = w.cli(args(bare), md);
      const b = w.cli(args(hashed), md);
      code(b, 0);
      code(a, 0);
      assert.ok(b.out.includes("PM-ck1") && b.out.includes(own.c1), brief(b));
      assert.strictEqual(a.out, b.out, `bare ${brief(a)} vs hashed ${brief(b)}`);
    });
  }
  for (const v of ["0", "3.2", "007", "-1"]) {
    test(`cli-issue-bare: --issue ${v} -> exit 2, nothing printed`, () => {
      const r = w.cli(["--timing", "before-companions", "--session", sid.bare, "--issue", v], md);
      code(r, 2);
      assert.strictEqual(r.out, "", brief(r));
    });
  }
}

module.exports = { argErrors, inputs, failures, timings, bareIssue };
