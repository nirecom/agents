"use strict";
// Tests: hooks/workflow-state/inheritance/granularity.js, hooks/workflow-state/inheritance/adopt.js, hooks/session-start.js, bin/lib/resume-session/upstream-view.js, bin/lib/resume-session/upstream-cwd.js, bin/lib/resume-session/args.js, bin/resume-session-detect, bin/workflow/adopt-session-state, skills/resume-session/SKILL.md
// Tags: feature-2297, readopt, overwrite-protection, upstream-cwd, inheritance-granularity, resume-session, state-unreadable, scope:issue-specific, TL2, pwsh-not-required
// #2297 (2c): granularity is a reported fact (SAME worktree -> full, anything else -> degraded), a
// re-adopt from the same upstream is allowed only while the downstream holds no record of its own,
// and the upstream's recorded cwd is classified before `--from` so the user can enter it first.
// Real `git worktree add` fixtures; state and plans dirs pinned by isolate().
// TL3 gap: only a real session proves that EnterWorktree writes the worktree event the re-adopt
// case simulates, and that the skill actually runs --classify-cwd before --from.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("./feature-2297-readopt-and-upstream-cwd/fixture");

const restoreIsolation = isolate();
const SB = F.makeSandbox();
const HOME_CWD = process.cwd();
process.chdir(SB.NEUTRAL);
after(() => {
  process.chdir(HOME_CWD);
  restoreIsolation();
  fs.rmSync(SB.base, { recursive: true, force: true });
  console.log(`\n${PASS} passed, ${FAIL} failed`);
});

const FULL = "full";
const DEGRADED = "context-independent-only";
const ADOPT = "hooks/workflow-state/inheritance/adopt.js";
const GRAN = "hooks/workflow-state/inheritance/granularity.js";
const CWDMOD = "bin/lib/resume-session/upstream-cwd.js";
const checkOverwrite = () => F.need(ADOPT, "checkOverwriteAllowed");
const decideGran = () => F.need(GRAN, "decideInheritanceGranularity");
const classify = () => F.need(CWDMOD, "classifyUpstreamCwd");
const read = (sid) => F.io().readState(sid);

let PASS = 0;
let FAIL = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS: ${name}`);
    PASS++;
  } catch (e) {
    console.log(`FAIL: ${name} — ${String(e && e.message).split("\n")[0]}`);
    FAIL++;
  }
}
const failures = () => FAIL;
const okAdopt = (r) => assert.ok(r && r.ok === true, `adopt refused: ${r && r.error}`);

caseBegin("readopt-same-upstream-recovers-full", "hooks/workflow-state/inheritance/adopt.js");
test("readopt-same-upstream-recovers-full", () => noNewFailures(failures, () => {
check("degraded from main, EnterWorktree, then the same --from again recovers full", () => {
  F.seedUpstream("up-c1", SB.W1);
  F.seedDownstream("down-c1", SB.M);
  const first = F.adopt("down-c1", "up-c1");
  okAdopt(first);
  assert.strictEqual(first.granularity, DEGRADED, "main vs linked worktree must adopt degraded");
  assert.strictEqual(F.statusOf("down-c1", "write_tests"), "pending");
  F.enterWorktree("down-c1", SB.W1);
  assert.strictEqual(read("down-c1").cwd, SB.W1, "fixture: the projected cwd did not move");
  const again = F.adopt("down-c1", "up-c1");
  okAdopt(again);
  assert.strictEqual(again.granularity, FULL);
  assert.strictEqual(F.statusOf("down-c1", "write_tests"), "complete");
  assert.strictEqual(F.io().readRawState("down-c1").upstream_session_id, "up-c1");
});
}));
caseEnd();

caseBegin("readopt-same-context-repeatedly-is-idempotent", "hooks/workflow-state/inheritance/adopt.js");
test("readopt-same-context-repeatedly-is-idempotent", () => noNewFailures(failures, () => {
check("re-adopting twice more with an unchanged context adds no events and no supervisor records", () => {
  F.seedUpstream("up-c1i", SB.W1);
  F.seedDownstream("down-c1i", SB.W1);
  okAdopt(F.adopt("down-c1i", "up-c1i"));
  const kindCounts = () => {
    const counts = {};
    for (const e of (F.io().readRawState("down-c1i") || {}).events || []) counts[e.kind] = (counts[e.kind] || 0) + 1;
    return counts;
  };
  const supPath = require(F.rel("hooks/lib/supervisor-state-writer")).getStatePath("down-c1i");
  const supBytes = () => (fs.existsSync(supPath) ? fs.readFileSync(supPath, "utf8") : null);
  const eventTotal = () => ((F.io().readRawState("down-c1i") || {}).events || []).length;
  const baseCounts = kindCounts();
  const baseTotal = eventTotal();
  const baseSup = supBytes();
  for (let i = 1; i <= 2; i++) {
    const r = F.adopt("down-c1i", "up-c1i");
    okAdopt(r);
    assert.strictEqual(r.granularity, FULL, `re-adopt #${i} changed the granularity`);
    assert.deepStrictEqual(kindCounts(), baseCounts, `re-adopt #${i} duplicated events by kind`);
    assert.strictEqual(eventTotal(), baseTotal, `re-adopt #${i} changed the event count`);
    assert.strictEqual(supBytes(), baseSup, `re-adopt #${i} wrote supervisor records`);
  }
});
}));
caseEnd();

caseBegin("readopt-allowed-lookahead-and-environment-facts", "hooks/workflow-state/inheritance/adopt.js");
test("readopt-allowed-lookahead-and-environment-facts", () => noNewFailures(failures, () => {
check("a lookahead in_progress plus session_model / worktree events do not block a re-adopt", () => {
  F.seedUpstream("up-c2", SB.W1);
  F.seedDownstream("down-c2", SB.W1);
  okAdopt(F.adopt("down-c2", "up-c2"));
  F.io().markStep("down-c2", "detail", "in_progress", {}, { provenance: "observed", origin: "postuse-in-flight" });
  F.io().recordSessionModel("down-c2", { modelId: "fixture-model" });
  F.enterWorktree("down-c2", SB.W1);
  const verdict = checkOverwrite()(F.io().readRawState("down-c2"), "up-c2");
  assert.strictEqual(verdict.ok, true, `checkOverwriteAllowed refused: ${verdict.error}`);
  okAdopt(F.adopt("down-c2", "up-c2"));
});
}));
caseEnd();

caseBegin("readopt-refused-after-reapproval", "hooks/workflow-state/inheritance/adopt.js");
test("readopt-refused-after-reapproval", () => noNewFailures(failures, () => {
check("a downstream CONFIRM_OUTLINE re-approval blocks the re-adopt; state bytes unchanged", () => {
  F.seedUpstream("up-c3", SB.W1);
  F.seedDownstream("down-c3", SB.W1);
  okAdopt(F.adopt("down-c3", "up-c3"));
  F.approvals().ensurePlan("up-c3", "outline");
  F.approvals().approveLive("down-c3", "outline");
  const seq = F.lastSeqOf("down-c3", "plan_approval");
  assert.ok(seq !== null, "fixture: no plan_approval recorded downstream");
  const before = F.bytes("down-c3");
  const r = F.adopt("down-c3", "up-c3");
  assert.strictEqual(r.ok, false, "re-adopt after re-approval must be refused");
  assert.match(String(r.error), /plan_approval/);
  assert.ok(String(r.error).includes(String(seq)), `error does not name seq ${seq}: ${r.error}`);
  assert.match(String(r.error), /new session/i, "the escape route is not offered");
  assert.doesNotMatch(String(r.error), /different upstream/i, "a retained record is not a different upstream");
  assert.strictEqual(F.bytes("down-c3"), before, "refused re-adopt mutated the downstream state");
  const v = checkOverwrite()(F.io().readRawState("down-c3"), "up-c3");
  assert.strictEqual(v.ok, false);
  assert.ok(Array.isArray(v.retained) && v.retained.length > 0 && v.retained[0].kind === "plan_approval",
    `retained: ${JSON.stringify(v.retained)}`);
});
}));
caseEnd();

caseBegin("readopt-refused-after-annotation-or-complete", "hooks/workflow-state/inheritance/adopt.js");
test("readopt-refused-after-annotation-or-complete", () => noNewFailures(failures, () => {
for (const [label, record, kind] of [
  ["annotation", (sid) => F.io().appendEvents(sid, [{ kind: "step_annotation", step: "research", key: "warnings_summary", value: "own note", provenance: "declared", origin: "test-fixture" }]), "step_annotation"],
  ["complete", (sid) => F.io().markStep(sid, "run_tests", "complete"), "step_status"],
]) {
  check(`one downstream ${label} blocks a re-adopt from the same upstream`, () => {
    const up = `up-c4-${label}`;
    const down = `down-c4-${label}`;
    F.seedUpstream(up, SB.W1);
    F.seedDownstream(down, SB.W1);
    okAdopt(F.adopt(down, up));
    record(down);
    const seq = F.lastSeqOf(down, kind);
    const before = F.bytes(down);
    const r = F.adopt(down, up);
    assert.strictEqual(r.ok, false, `re-adopt after a downstream ${label} must be refused`);
    assert.ok(String(r.error).includes(kind) && String(r.error).includes(String(seq)), `error: ${r.error}`);
    assert.strictEqual(F.bytes(down), before);
  });
}
}));
caseEnd();

caseBegin("adopt-refused-from-different-upstream", "hooks/workflow-state/inheritance/adopt.js");
test("adopt-refused-from-different-upstream", () => noNewFailures(failures, () => {
check("a downstream adopted from A refuses B, and says it is a different upstream", () => {
  F.seedUpstream("up-c5a", SB.W1);
  F.seedUpstream("up-c5b", SB.W1);
  F.seedDownstream("down-c5", SB.W1);
  okAdopt(F.adopt("down-c5", "up-c5a"));
  const before = F.bytes("down-c5");
  const r = F.adopt("down-c5", "up-c5b");
  assert.strictEqual(r.ok, false);
  assert.ok(/different upstream/i.test(String(r.error)) || String(r.error).includes("up-c5a"), `error: ${r.error}`);
  assert.strictEqual(F.bytes("down-c5"), before);
});
check("a downstream with its own work and no upstream_session_id is refused (any upstream)", () => {
  F.seedUpstream("up-c5c", SB.W1);
  F.seedDownstream("down-c5c", SB.W1);
  F.io().markStep("down-c5c", "research", "complete");
  const v = checkOverwrite()(F.io().readRawState("down-c5c"), "up-c5c");
  assert.strictEqual(v.ok, false);
  assert.strictEqual(F.adopt("down-c5c", "up-c5c").ok, false);
});
}));
caseEnd();

caseBegin("all-pending-no-upstream-allowed-from-any", "hooks/workflow-state/inheritance/adopt.js");
test("all-pending-no-upstream-allowed-from-any", () => noNewFailures(failures, () => {
check("an untouched downstream may adopt from any upstream; isAllPending stays exported", () => {
  F.seedUpstream("up-c6", SB.W1);
  F.seedDownstream("down-c6", SB.W1);
  const raw = F.io().readRawState("down-c6");
  for (const up of ["up-c6", "some-other-upstream"]) {
    assert.strictEqual(checkOverwrite()(raw, up).ok, true, `refused for ${up}`);
  }
  assert.strictEqual(typeof require(F.rel(ADOPT)).isAllPending, "function");
  okAdopt(F.adopt("down-c6", "up-c6"));
});
}));
caseEnd();

caseBegin("granularity-decided-from-where-downstream-runs", "hooks/workflow-state/inheritance/granularity.js");
test("granularity-decided-from-where-downstream-runs", () => noNewFailures(failures, () => {
check("fixture anchors: W1/W1 same, W1/W2 sibling, W1/other different, W1/main sibling", () => {
  const { compareRepoIdentity, VERDICTS } = require(F.rel("hooks/lib/repo-identity.js"));
  assert.strictEqual(compareRepoIdentity(SB.W1, SB.W1), VERDICTS.SAME);
  assert.strictEqual(compareRepoIdentity(SB.W1, SB.W2), VERDICTS.SIBLING);
  assert.strictEqual(compareRepoIdentity(SB.W1, SB.O), VERDICTS.DIFFERENT);
  assert.strictEqual(compareRepoIdentity(SB.M, SB.W1), VERDICTS.SIBLING);
});
check("SAME -> full, SIBLING with equal content -> degraded, other repo -> degraded, no cwd -> degraded", () => {
  F.seedUpstream("up-c7", SB.W1);
  const up = read("up-c7");
  const g = decideGran();
  assert.strictEqual(g(SB.W1, up), FULL);
  assert.strictEqual(g(SB.W2, up), DEGRADED);
  assert.strictEqual(g(SB.O, up), DEGRADED);
  F.seedUpstream("up-c7-nocwd", null);
  assert.strictEqual(g(SB.W1, read("up-c7-nocwd")), DEGRADED);
});
}));
caseEnd();

caseBegin("adopt-sibling-equal-content-still-degraded", "hooks/workflow-state/inheritance/adopt.js");
test("adopt-sibling-equal-content-still-degraded", () => noNewFailures(failures, () => {
check("adoptState ignores verifiedEquivalent / granularity inputs and degrades a SIBLING", () => {
  F.seedUpstream("up-c8", SB.W1);
  F.seedDownstream("down-c8", SB.W2);
  const { adoptState } = require(F.rel(ADOPT));
  const r = adoptState({ heirSid: "down-c8", donorSid: "up-c8", granularity: FULL, verifiedEquivalent: true });
  okAdopt(r);
  assert.strictEqual(r.granularity, DEGRADED);
  assert.strictEqual(F.statusOf("down-c8", "write_tests"), "pending");
  assert.strictEqual(F.statusOf("down-c8", "research"), "complete");
});
check("a different-repo upstream is adopted degraded, not refused", () => {
  F.seedUpstream("up-c8o", SB.W1);
  F.seedDownstream("down-c8o", SB.O);
  const r = F.adopt("down-c8o", "up-c8o");
  okAdopt(r);
  assert.strictEqual(r.granularity, DEGRADED);
});
check("a missing intent artifact still forces degraded even in the SAME worktree", () => {
  F.seedUpstream("up-c8i", SB.W1);
  F.seedDownstream("down-c8i", SB.W1);
  fs.unlinkSync(path.join(process.env.WORKFLOW_PLANS_DIR, "up-c8i-intent.md"));
  const r = F.adopt("down-c8i", "up-c8i");
  okAdopt(r);
  assert.deepStrictEqual([r.granularity, r.degraded_reason], [DEGRADED, "intent-artifact-missing"]);
});
}));
caseEnd();

caseBegin("adopt-cli-granularity-flags-removed", "bin/workflow/adopt-session-state");
test("adopt-cli-granularity-flags-removed", () => noNewFailures(failures, () => {
for (const flags of [["--verified-equivalent"], ["--granularity", "full"]]) {
  check(`adopt-session-state ${flags[0]} exits 2 with the removal notice and adopts nothing`, () => {
    const tag = flags[0].replace(/^-+/, "");
    F.seedUpstream(`up-c9-${tag}`, SB.W1);
    F.seedDownstream(`down-c9-${tag}`, SB.W1);
    const before = F.bytes(`down-c9-${tag}`);
    const r = F.runNode([F.rel("bin/workflow/adopt-session-state"), "--session", `down-c9-${tag}`,
      "--from", `up-c9-${tag}`, ...flags], {}, SB.NEUTRAL);
    assert.strictEqual(r.rc, 2, `rc=${r.rc} out=${r.out} err=${r.err}`);
    assert.ok(r.err.includes("removed: granularity is decided from where this session runs"), `stderr: ${r.err}`);
    assert.strictEqual(F.bytes(`down-c9-${tag}`), before);
  });
}
}));
caseEnd();

caseBegin("classify-upstream-cwd-four-classes", "bin/lib/resume-session/upstream-cwd.js");
test("classify-upstream-cwd-four-classes", () => noNewFailures(failures, () => {
check("live linked worktree / main only / path deleted / no state or no cwd", () => {
  const c = classify();
  F.seedUpstream("up-c10-live", SB.W1);
  const live = c("up-c10-live");
  assert.strictEqual(F.classOf(live), "live-linked-worktree");
  assert.strictEqual(path.resolve(live.worktree_path), path.resolve(SB.W1));
  F.seedUpstream("up-c10-main", SB.M);
  assert.strictEqual(F.classOf(c("up-c10-main")), "main-worktree");
  F.seedUpstream("up-c10-gone", SB.W3);
  fs.rmSync(SB.W3, { recursive: true, force: true });
  assert.strictEqual(F.classOf(c("up-c10-gone")), "worktree-gone");
  assert.strictEqual(F.classOf(c("up-c10-no-such-session")), "cwd-unknown");
  F.seedUpstream("up-c10-nocwd", null);
  assert.strictEqual(F.classOf(c("up-c10-nocwd")), "cwd-unknown");
});
check("state.cwd on main falls through to a live session_worktree", () => {
  F.seedUpstream("up-c10-sw", SB.M);
  F.io().recordSessionWorktree("up-c10-sw", SB.W2);
  const r = classify()("up-c10-sw");
  assert.strictEqual(F.classOf(r), "live-linked-worktree");
  assert.strictEqual(path.resolve(r.worktree_path), path.resolve(SB.W2));
});
}));
caseEnd();

caseBegin("classify-cwd-args", "bin/lib/resume-session/args.js");
test("classify-cwd-args", () => noNewFailures(failures, () => {
check("--classify-cwd <sid> parses to its own mode; a bare --classify-cwd is an error", () => {
  const { parseResumeArgs } = require(F.rel("bin/lib/resume-session/args.js"));
  const ok = parseResumeArgs(["--classify-cwd", "sid-x"]);
  assert.notStrictEqual(ok.mode, "error", JSON.stringify(ok));
  assert.match(String(ok.mode), /classify/);
  assert.ok(JSON.stringify(ok).includes("sid-x"));
  assert.strictEqual(parseResumeArgs(["--classify-cwd"]).mode, "error");
});
}));
caseEnd();

caseBegin("classify-cwd-cli-json", "bin/resume-session-detect");
test("classify-cwd-cli-json", () => noNewFailures(failures, () => {
check("resume-session-detect --classify-cwd prints the classification as JSON", () => {
  F.seedUpstream("up-c11", SB.W1);
  const r = F.runNode([F.rel("bin/resume-session-detect"), "--classify-cwd", "up-c11"],
    { CLAUDE_CODE_SESSION_ID: "cli-heir-c11" }, SB.NEUTRAL);
  assert.strictEqual(r.rc, 0, `rc=${r.rc} err=${r.err}`);
  const j = JSON.parse(r.out);
  assert.strictEqual(F.classOf(j), "live-linked-worktree");
  assert.strictEqual(path.resolve(j.worktree_path), path.resolve(SB.W1));
});
check("a traversal sid is never classified as a live worktree", () => {
  const r = F.runNode([F.rel("bin/resume-session-detect"), "--classify-cwd", "../../etc"],
    { CLAUDE_CODE_SESSION_ID: "cli-heir-c11" }, SB.NEUTRAL);
  assert.ok(!/Unknown flag/.test(r.out + r.err), `flag not recognized: ${r.out}${r.err}`);
  let cls = null;
  try { cls = F.classOf(JSON.parse(r.out)); } catch (_) { cls = null; }
  assert.ok(r.rc !== 0 || cls === "cwd-unknown", `rc=${r.rc} out=${r.out}`);
  assert.doesNotMatch(r.err, /^\s+at /m, "stack trace leaked");
});
}));
caseEnd();

caseBegin("list-preview-agrees-with-overwrite-and-granularity", "bin/lib/resume-session/upstream-view.js");
test("list-preview-agrees-with-overwrite-and-granularity", () => noNewFailures(failures, () => {
check("--list preview = checkOverwriteAllowed + decideInheritanceGranularity", () => {
  const view = require(F.rel("bin/lib/resume-session/upstream-view.js"));
  F.seedUpstream("up-c12-same", SB.W1);
  F.seedUpstream("up-c12-sib", SB.W2);
  F.seedDownstream("down-c12", SB.W1);
  const ow = checkOverwrite();
  const g = decideGran();
  const rec = (sid, cwd) => ({ sid, adoptable: true, adoptable_reason: "context-match", cwd, resumability_degraded_reason: null });
  const fresh = view.createAdoptabilityPreviewer({ heirSid: "down-c12" });
  for (const [sid, cwd] of [["up-c12-same", SB.W1], ["up-c12-sib", SB.W2]]) {
    const p = fresh.preview(rec(sid, cwd));
    assert.strictEqual(p.adoptable, ow(F.io().readRawState("down-c12"), sid).ok, sid);
    assert.strictEqual(p.adoptable_granularity, g(SB.W1, read(sid)), sid);
  }
  assert.strictEqual(view.decideGranularity(SB.W2, SB.W1).granularity, DEGRADED);
  F.seedDownstream("down-c12-own", SB.W1);
  F.io().markStep("down-c12-own", "research", "complete");
  const p = view.createAdoptabilityPreviewer({ heirSid: "down-c12-own" }).preview(rec("up-c12-same", SB.W1));
  assert.strictEqual(ow(F.io().readRawState("down-c12-own"), "up-c12-same").ok, false);
  assert.deepStrictEqual([p.adoptable, p.adoptable_granularity], [false, null]);
});
check("--from on a SIBLING reports degraded with no verified-equivalent claim", () => {
  const view = require(F.rel("bin/lib/resume-session/upstream-view.js"));
  F.seedUpstream("up-c12-from", SB.W2);
  F.seedDownstream("down-c12-from", SB.W1);
  const ir = view.buildUpstreamView({ heirSid: "down-c12-from", upstreamSid: "up-c12-from" }).inherit_result || {};
  assert.strictEqual(ir.ok, true, `refused: ${ir.error}`);
  assert.strictEqual(ir.granularity, DEGRADED);
  assert.notStrictEqual(ir.verified_equivalent, true);
});
}));
caseEnd();

caseBegin("session-start-uses-decide-granularity", "hooks/session-start.js");
test("session-start-uses-decide-granularity", () => noNewFailures(failures, () => {
check("the automatic inheritance path decides granularity through decideInheritanceGranularity", () => {
  const src = fs.readFileSync(F.rel("hooks/session-start.js"), "utf8");
  assert.match(src, /decideInheritanceGranularity/);
});
}));
caseEnd();

caseBegin("skill-rsm2-classify-before-from", "skills/resume-session/SKILL.md");
test("skill-rsm2-classify-before-from", () => noNewFailures(failures, () => {
check("RSM-2 classifies, enters the worktree, warns about cd, explains recovery; no --verified-equivalent", () => {
  const text = fs.readFileSync(F.rel("skills/resume-session/SKILL.md"), "utf8");
  const m = /### RSM-2[\s\S]*?(?=\n### )/.exec(text);
  assert.ok(m, "RSM-2 section not found");
  const lines = m[0].split("\n");
  const at = (re) => lines.findIndex((l) => re.test(l));
  const classifyAt = at(/--classify-cwd/);
  const fromAt = at(/resume-session-detect"? --from/);
  assert.ok(classifyAt !== -1, "no --classify-cwd line");
  assert.ok(fromAt === -1 || classifyAt < fromAt, "--classify-cwd must come before --from");
  assert.ok(at(/live-linked-worktree/) !== -1 && at(/EnterWorktree/) !== -1 && at(/worktree_path/) !== -1, "no EnterWorktree line");
  assert.ok(at(/worktree-gone/) !== -1 && at(/cwd-unknown/) !== -1, "no worktree-gone / cwd-unknown line");
  assert.ok(at(/`cd`/) !== -1 && at(/state\.cwd/) !== -1, "no Bash cd warning");
  assert.ok(lines.some((l) => /degraded/i.test(l) && /--from/.test(l) && /worktree/i.test(l)), "no recovery line");
  assert.doesNotMatch(text, /--verified-equivalent/);
});
}));
caseEnd();

// A corrupt state file is damage, not expiry: the ARTIFACTS_ONLY branch must say so as the NONE branch does.
caseBegin("from-artifacts-only-distinguishes-unreadable-from-expired", "bin/lib/resume-session/upstream-view.js");
test("from-artifacts-only-distinguishes-unreadable-from-expired", () => noNewFailures(failures, () => {
const seedIntent = (sid) => fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-intent.md`), "**Title:** fixture\n");
check("corrupt state + intent artifact -> artifacts-only, inherit_result reason state-unreadable", () => {
  const view = require(F.rel("bin/lib/resume-session/upstream-view.js"));
  F.seedDownstream("down-c13-bad", SB.W1);
  fs.mkdirSync(path.dirname(F.statePath("up-c13-bad")), { recursive: true });
  fs.writeFileSync(F.statePath("up-c13-bad"), "{ not json");
  seedIntent("up-c13-bad");
  const v = view.buildUpstreamView({ heirSid: "down-c13-bad", upstreamSid: "up-c13-bad" });
  assert.strictEqual(v.availability, "artifacts-only");
  assert.ok((v.state_handoff_errors || []).includes("state"), `errors: ${JSON.stringify(v.state_handoff_errors)}`);
  assert.deepStrictEqual(v.inherit_result, { attempted: false, reason: "state-unreadable" });
});
check("absent state + intent artifact -> artifacts-only, inherit_result reason state_expired", () => {
  const view = require(F.rel("bin/lib/resume-session/upstream-view.js"));
  F.seedDownstream("down-c13-gone", SB.W1);
  seedIntent("up-c13-gone");
  assert.strictEqual(fs.existsSync(F.statePath("up-c13-gone")), false, "fixture: state file exists");
  const v = view.buildUpstreamView({ heirSid: "down-c13-gone", upstreamSid: "up-c13-gone" });
  assert.strictEqual(v.availability, "artifacts-only");
  assert.strictEqual((v.inherit_result || {}).reason, "state_expired");
});
}));
caseEnd();
