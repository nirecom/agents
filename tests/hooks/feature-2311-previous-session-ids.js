#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io.js, hooks/session-start.js, bin/resume-session-detect
// Tags: TL2, session-inherit, workflow-state, session-chain, regression-2311, progress-file, regression-2748, scope:issue-specific, pwsh-not-required
// #2311: every inheritance writes previous_session_ids = the upstream's own chain plus the
// upstream sid, oldest first, de-duplicated (first occurrence kept), with every element a valid
// sid. The chain comes from upstream.previous_session_ids when it is an array, else from a valid
// upstream.upstream_session_id, else it is empty.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2311-"));
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const F = require("./feature-2304-inheritance-state-copy/fixture");

let passed = 0;
let failed = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const failures = () => failed;
const apply = () => F.mod("hooks/workflow-state/inheritance/apply");
// inherit(down, up) — a fresh downstream adopting from up; returns the downstream's chain.
function inherit(down, up) {
  const createdAt = F.seedDownstream(down);
  apply().applyInheritance(down, createdAt, up);
  return F.raw(down).previous_session_ids;
}

caseBegin("persisted-key-allow-list", "hooks/workflow-state/state-io/projection.js");
test("persisted-key-allow-list", () => noNewFailures(failures, () => {
  check("A1: projection's PERSISTED_TOP_LEVEL_KEYS includes previous_session_ids", () => {
    const keys = Array.from(F.mod("hooks/workflow-state/state-io/projection").PERSISTED_TOP_LEVEL_KEYS || []);
    eq(keys.indexOf("previous_session_ids") !== -1, true, "in projection allow-list");
  });
  check("A1: state-io re-exports the same allow-list with previous_session_ids", () => {
    const keys = Array.from(F.S().PERSISTED_TOP_LEVEL_KEYS || []);
    eq(keys.indexOf("previous_session_ids") !== -1, true, "in state-io allow-list");
  });
  check("A1: previous_session_ids sits right after upstream_copy_seq", () => {
    const keys = Array.from(F.mod("hooks/workflow-state/state-io/projection").PERSISTED_TOP_LEVEL_KEYS || []);
    eq(keys.indexOf("previous_session_ids"), keys.indexOf("upstream_copy_seq") + 1, "position");
  });
  check("A2: writeState accepts previous_session_ids and it survives a read", () => {
    const io = F.S();
    const st = io.createInitialState("f2311-allow", F.UP_CTX);
    st.previous_session_ids = ["f2311-a", "f2311-b"];
    io.writeState("f2311-allow", st);
    eq(F.raw("f2311-allow").previous_session_ids, ["f2311-a", "f2311-b"], "persisted value");
  });
}));
caseEnd();

caseBegin("lineage-chain-accumulates", "hooks/workflow-state/inheritance/apply.js");
test("lineage-chain-accumulates", () => noNewFailures(failures, () => {
  check("P5: an upstream with no lineage fields gives [upstreamSid]", () => {
    F.seedUpstream("p5-up");
    eq(inherit("p5-down", "p5-up"), ["p5-up"], "previous_session_ids");
  });
  check("P1: A -> B -> C -> D leaves D with [A, B, C], oldest first", () => {
    F.seedUpstream("p1-a");
    eq(inherit("p1-b", "p1-a"), ["p1-a"], "B");
    eq(inherit("p1-c", "p1-b"), ["p1-a", "p1-b"], "C");
    eq(inherit("p1-d", "p1-c"), ["p1-a", "p1-b", "p1-c"], "D");
  });
  check("P2: re-adopting B from A twice still gives [A]", () => {
    F.seedUpstream("p2-a");
    eq(inherit("p2-b", "p2-a"), ["p2-a"], "first adoption");
    apply().applyInheritance("p2-b", F.raw("p2-b").created_at, "p2-a");
    eq(F.raw("p2-b").previous_session_ids, ["p2-a"], "second adoption");
  });
  check("P6: B carrying only upstream_session_id = A gives C [A, B]", () => {
    F.seedUpstream("p6-b");
    const b = F.raw("p6-b");
    delete b.previous_session_ids;
    b.upstream_session_id = "p6-a";
    F.writeRaw("p6-b", b);
    eq(inherit("p6-c", "p6-b"), ["p6-a", "p6-b"], "previous_session_ids");
  });
}));
caseEnd();

caseBegin("lineage-chain-sanitized", "hooks/workflow-state/inheritance/apply.js");
test("lineage-chain-sanitized", () => noNewFailures(failures, () => {
  check("P3: invalid elements of the upstream chain are dropped and duplicates keep the first", () => {
    F.seedUpstream("p3-up");
    const up = F.raw("p3-up");
    up.previous_session_ids = ["p3-a", "../x", 7, "a.b", null, "p3-a", "p3-b", "a/b", ""];
    F.writeRaw("p3-up", up);
    eq(inherit("p3-down", "p3-up"), ["p3-a", "p3-b", "p3-up"], "previous_session_ids");
  });
  check("P3: an upstream chain that already names the upstream does not repeat it", () => {
    F.seedUpstream("p3d-up");
    const up = F.raw("p3d-up");
    up.previous_session_ids = ["p3d-a", "p3d-up"];
    F.writeRaw("p3d-up", up);
    eq(inherit("p3d-down", "p3d-up"), ["p3d-a", "p3d-up"], "previous_session_ids");
  });
  check("P7: a non-array chain falls back to a valid upstream_session_id", () => {
    F.seedUpstream("p7-up");
    const up = F.raw("p7-up");
    up.previous_session_ids = "p7-not-an-array";
    up.upstream_session_id = "p7-a";
    F.writeRaw("p7-up", up);
    eq(inherit("p7-down", "p7-up"), ["p7-a", "p7-up"], "previous_session_ids");
  });
  check("P8: an invalid upstream_session_id and no chain give [upstreamSid]", () => {
    F.seedUpstream("p8-up");
    const up = F.raw("p8-up");
    delete up.previous_session_ids;
    up.upstream_session_id = "../p8-escape";
    F.writeRaw("p8-up", up);
    eq(inherit("p8-down", "p8-up"), ["p8-up"], "previous_session_ids");
  });
}));
caseEnd();

caseBegin("persisted-key-allow-deny-table", "hooks/workflow-state/state-io/projection.js");
test("persisted-key-allow-deny-table", () => noNewFailures(failures, () => {
  const rows = [
    { key: "previous_session_ids", value: ["f2311-t-a"], verdict: "allow" },
    { key: "upstream_session_id", value: "f2311-t-a", verdict: "allow" },
    { key: "previous_session_idz", value: ["f2311-t-a"], verdict: "deny" },
    { key: "previous_session_id", value: "f2311-t-a", verdict: "deny" },
  ];
  for (const row of rows) {
    check(`A3: top-level key ${row.key} is ${row.verdict === "allow" ? "persisted" : "rejected with UnknownStateKeyError"}`, () => {
      const io = F.S();
      const sid = `f2311-tbl-${row.key.replace(/_/g, "-")}`;
      const st = io.createInitialState(sid, F.UP_CTX);
      st[row.key] = row.value;
      let err = null;
      try { io.writeState(sid, st); } catch (e) { err = e; }
      if (row.verdict === "allow") {
        eq(err && err.name, null, "writeState error");
        eq(F.raw(sid)[row.key], row.value, "persisted value");
      } else {
        eq(err && err.name, "UnknownStateKeyError", "writeState error name");
        eq(err instanceof io.UnknownStateKeyError, true, "instanceof UnknownStateKeyError");
        eq(fs.existsSync(F.statePath(sid)), false, "state file written despite the rejection");
      }
    });
  }
}));
caseEnd();

caseBegin("from-cli-chain-persists-lineage", "bin/resume-session-detect");
test("from-cli-chain-persists-lineage", () => noNewFailures(failures, () => {
  // Each hop is a real `resume-session-detect --from` run with the heir as the session id;
  // the assertion reads the heir's state file the CLI left on disk.
  const CLI = path.join(F.ROOT, "bin", "resume-session-detect");
  const CTX = { cwd: "/fixture/f2311-cli/repo", git_branch: "feature/f2311-cli" };
  const home = fs.mkdtempSync(path.join(SCRATCH, "cli-home-"));
  const tbase = fs.mkdtempSync(path.join(SCRATCH, "cli-transcripts-"));
  function adoptViaCli(heir, up) {
    const io = F.S();
    io.writeState(heir, io.createInitialState(heir, CTX));
    const env = Object.assign({}, process.env, {
      HOME: home, USERPROFILE: home, CLAUDE_TRANSCRIPT_BASE_DIR: tbase, CLAUDE_CODE_SESSION_ID: heir,
    });
    const run = spawnSync(process.execPath, [CLI, "--from", up], { cwd: home, env, encoding: "utf8", timeout: 60000 });
    let d = null;
    try { d = JSON.parse(run.stdout); } catch (e) { d = null; }
    const ir = d && d.inherit_result;
    if (run.status !== 0 || !ir || ir.ok !== true) {
      throw new Error(`--from ${up} as ${heir} did not adopt: exit=${run.status} inherit_result=${show(ir)} stderr=${show(run.stderr)}`);
    }
    return F.raw(heir);
  }
  check("C1: A -> B -> C through the --from CLI persists [A] on B and [A, B] on C", () => {
    const a = "f2311-cli-a";
    const io = F.S();
    io.writeState(a, io.createInitialState(a, CTX));
    io.markStep(a, "workflow_init", "complete");
    fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${a}-intent.md`), "**Title:** f2311 cli chain\n");
    require(path.join(F.ROOT, "tests/lib/plan-approval-fixture")).approveLive(a, "clarify_intent");
    io.markStep(a, "clarify_intent", "complete");
    const b = adoptViaCli("f2311-cli-b", a);
    eq(b.upstream_session_id, a, "B upstream_session_id");
    eq(b.previous_session_ids, [a], "B persisted previous_session_ids");
    const c = adoptViaCli("f2311-cli-c", "f2311-cli-b");
    eq(c.upstream_session_id, "f2311-cli-b", "C upstream_session_id");
    eq(c.previous_session_ids, [a, "f2311-cli-b"], "C persisted previous_session_ids");
  });
}));
caseEnd();

caseBegin("session-start-writes-same-lineage", "hooks/session-start.js");
test("session-start-writes-same-lineage", () => noNewFailures(failures, () => {
  check("P4: the SessionStart inheritance writes the same chain as an explicit applyInheritance", () => {
    F.seedUpstream("p4-root");
    inherit("p4-up", "p4-root");
    const explicit = inherit("p4-explicit", "p4-up");
    const preload = path.join(SCRATCH, "force-upstream.js");
    fs.writeFileSync(preload, `const b = require(${JSON.stringify(path.join(F.ROOT, "hooks/workflow-state"))});\n` +
      "b.resolveInheritanceDonor = () => ({ donor: { session_id: 'p4-up' }, decision: 'inherited', candidateSessionId: 'p4-up', ancestors: [] });\n");
    const home = fs.mkdtempSync(path.join(SCRATCH, "home-"));
    const tbase = fs.mkdtempSync(path.join(SCRATCH, "transcripts-"));
    const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home, CLAUDE_TRANSCRIPT_BASE_DIR: tbase });
    delete env.CLAUDE_CODE_SESSION_ID;
    const run = spawnSync(process.execPath, ["-r", preload, path.join(F.ROOT, "hooks/session-start.js")], {
      cwd: home, env, encoding: "utf8", timeout: 60000,
      input: JSON.stringify({ session_id: "p4-ss", source: "resume", transcript_path: path.join(tbase, "p4-ss.jsonl") }),
    });
    eq(fs.existsSync(F.statePath("p4-ss")), true, "session-start state file exists (stderr " + show(run.stderr) + ")");
    eq(run.status, 0, "session-start exit (stderr " + show(run.stderr) + ")");
    const viaHook = F.raw("p4-ss");
    eq(viaHook.upstream_session_id, "p4-up", "the hook inherited from p4-up");
    eq(viaHook.previous_session_ids, explicit, "hook chain vs explicit chain");
    eq(viaHook.previous_session_ids, ["p4-root", "p4-up"], "hook chain");
  });
}));
caseEnd();

// #2748: every inheritance writes first_session_id = resolveFirstSid(upstream) into the copy, so
// each generation names the first generation of its session chain without a walk. A first generation
// carries no first_session_id. A legacy upstream is a raw state carrying upstream_session_id only.
const PF = F.mod("hooks/lib/progress-file");
// adopt(down, up) — like inherit, but fails loudly and returns the downstream's whole state.
function adopt(down, up) {
  const createdAt = F.seedDownstream(down);
  const res = apply().applyInheritance(down, createdAt, up);
  if (!res || res.ok === false) throw new Error(`applyInheritance(${down}, ${up}) failed: ${show(res)}`);
  return F.raw(down);
}

caseBegin("persisted-key-first-session-id", "hooks/workflow-state/state-io/projection.js");
test("persisted-key-first-session-id", () => noNewFailures(failures, () => {
  check("A7: PERSISTED_TOP_LEVEL_KEYS lists first_session_id right after previous_session_ids", () => {
    const keys = Array.from(F.mod("hooks/workflow-state/state-io/projection").PERSISTED_TOP_LEVEL_KEYS || []);
    eq(keys.indexOf("first_session_id") !== -1, true, "first_session_id in the allow-list");
    eq(keys.indexOf("first_session_id"), keys.indexOf("previous_session_ids") + 1, "position");
  });
}));
caseEnd();

caseBegin("build-copy-writes-first-session-id", "hooks/workflow-state/inheritance/apply.js");
test("build-copy-writes-first-session-id", () => noNewFailures(failures, () => {
  check("A7: A -> B writes B.first_session_id = A", () => {
    F.seedUpstream("a7-a");
    eq(adopt("a7-b", "a7-a").first_session_id, "a7-a", "B.first_session_id");
  });
  check("A8: A -> B -> C writes C.first_session_id = A and previous_session_ids [A, B]", () => {
    F.seedUpstream("a8-a");
    adopt("a8-b", "a8-a");
    const c = adopt("a8-c", "a8-b");
    eq(c.first_session_id, "a8-a", "C.first_session_id");
    eq(c.previous_session_ids, ["a8-a", "a8-b"], "C.previous_session_ids");
  });
  check("A8: A -> B -> C -> D keeps first_session_id = A on D", () => {
    F.seedUpstream("a8d-a");
    adopt("a8d-b", "a8d-a");
    adopt("a8d-c", "a8d-b");
    eq(adopt("a8d-d", "a8d-c").first_session_id, "a8d-a", "D.first_session_id");
  });
}));
caseEnd();

caseBegin("build-copy-first-session-id-from-self-pinned-or-legacy-upstream", "hooks/workflow-state/inheritance/apply.js");
test("build-copy-first-session-id-from-self-pinned-or-legacy-upstream", () => noNewFailures(failures, () => {
  check("A9: a self-pinned upstream (no first_session_id field) still gives C.first_session_id = A", () => {
    F.seedUpstream("a9-a");
    const b = adopt("a9-b", "a9-a");
    // B as written before #2748: no first_session_id, and its sidecar pinned to itself (a self-pinned sidecar).
    delete b.first_session_id;
    F.writeRaw("a9-b", b);
    if (!PF.mergePressure("a9-b", { root_sid: "a9-b" })) throw new Error("could not pin a9-b");
    eq(adopt("a9-c", "a9-b").first_session_id, "a9-a", "C.first_session_id");
  });
  check("A9b: a legacy upstream (upstream_session_id only) gives C.first_session_id = A and the #2311 chain", () => {
    F.seedUpstream("a9b-a");
    F.seedUpstream("a9b-b");
    const b = F.raw("a9b-b");
    delete b.previous_session_ids;
    delete b.first_session_id;
    b.upstream_session_id = "a9b-a";
    F.writeRaw("a9b-b", b);
    const c = adopt("a9b-c", "a9b-b");
    eq(c.first_session_id, "a9b-a", "C.first_session_id");
    eq(c.previous_session_ids, ["a9b-a", "a9b-b"], "C.previous_session_ids");
  });
  check("A9b: a three-generation legacy upstream chain resolves to its oldest member", () => {
    F.seedUpstream("a9c-a");
    F.seedUpstream("a9c-b");
    F.seedUpstream("a9c-c");
    const b = F.raw("a9c-b");
    delete b.previous_session_ids;
    b.upstream_session_id = "a9c-a";
    F.writeRaw("a9c-b", b);
    const c = F.raw("a9c-c");
    delete c.previous_session_ids;
    c.upstream_session_id = "a9c-b";
    F.writeRaw("a9c-c", c);
    eq(adopt("a9c-d", "a9c-c").first_session_id, "a9c-a", "D.first_session_id");
  });
}));
caseEnd();

caseBegin("first-generation-has-no-first-session-id", "hooks/workflow-state/inheritance/apply.js");
test("first-generation-has-no-first-session-id", () => noNewFailures(failures, () => {
  check("A10: a first generation carries no first_session_id", () => {
    F.seedUpstream("a10-a");
    eq(Object.prototype.hasOwnProperty.call(F.raw("a10-a"), "first_session_id"), false, "first_session_id key on A");
  });
  check("A10: inheriting from A leaves A without first_session_id", () => {
    F.seedUpstream("a10b-a");
    const b = adopt("a10b-b", "a10b-a");
    eq(Object.prototype.hasOwnProperty.call(F.raw("a10b-a"), "first_session_id"), false, "first_session_id key on A");
    eq(b.first_session_id, "a10b-a", "B.first_session_id");
  });
}));
caseEnd();
