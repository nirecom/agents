#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/plan-artifact-owner.js, bin/plan-artifact-path, hooks/lib/presentation-receipt.js, bin/lib/glossary-provenance.js, hooks/lib/plan-artifact-lang.js, bin/lib/resume-session/upstream-view.js
// Tags: TL2, regression-2748, scope:issue-specific, plan-artifact, pwsh-not-required
// #2748 U1-U7: every generation of a session chain reads and writes the plan artifacts under the
// first_session_id name. The chain here has three generations (first, session-upstream,
// session-downstream) built with the real applyInheritance; the session-upstream writes no plan.
// U3 is a static check of the writers. U8/U9 (the shell writers run for real) live in
// tests/skills/fix-2748-plan-name-unification-scripts.sh.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2748-unify-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
delete process.env.CLAUDE_CODE_SESSION_ID;
process.on("exit", () => {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const F = require("./feature-2304-inheritance-state-copy/fixture");
const PLANS = process.env.WORKFLOW_PLANS_DIR;

// check(name, fn) — one node:test test; fn fails it by throwing or by returning a message string.
function check(name, fn) {
  test(name, () => {
    const why = fn();
    if (typeof why === "string") assert.fail(why.replace(/[\r\n]+/g, " ").slice(0, 400));
  });
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
const samePath = (a, b) => {
  const n = (p) => path.resolve(String(p || "")).replace(/\\/g, "/").toLowerCase();
  return typeof a === "string" && a !== "" && n(a) === n(b);
};
const planOf = (sid, stage) => path.join(PLANS, `${sid}-${stage}.md`);
const neutral = fs.mkdtempSync(path.join(SCRATCH, "cwd-"));
function childEnv(extra) {
  const env = Object.assign({}, process.env, { HOME: neutral, USERPROFILE: neutral }, extra || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  return env;
}

// The first generation's intent carries a glossary table, so U5 can read it as an approved intent.
const INTENT_BODY = "# Agreed Requirements — fixture\n\n## Issues\n\n- #1 fixture\n\n## Glossary\n\n" +
  "| Term | Category | Operation | Definition |\n|---|---|---|---|\n| alpha | user | add | The first fixture term. |\n\n" +
  "## Background / Motivation\n\nFixture background.\n";

// chain() — first (seedUpstream: an approved intent), session-upstream adopts first, session-downstream
// adopts the session-upstream. Only the first generation has plan files: intent, and a detail with no approval.
function chain(opts) {
  const o = opts || {};
  const firstSid = crypto.randomUUID();
  const upstreamSid = crypto.randomUUID();
  const downstreamSid = crypto.randomUUID();
  fs.writeFileSync(planOf(firstSid, "intent"), INTENT_BODY);
  F.seedUpstream(firstSid);
  if (o.detail) fs.writeFileSync(planOf(firstSid, "detail"), "# detail\n\nfirst generation detail\n");
  const apply = F.mod("hooks/workflow-state/inheritance/apply").applyInheritance;
  for (const [sid, from] of [[upstreamSid, firstSid], [downstreamSid, upstreamSid]]) {
    const res = apply(sid, F.seedDownstream(sid), from);
    if (!res || res.ok === false) throw new Error(`applyInheritance(${sid}, ${from}) failed: ${show(res)}`);
  }
  return { firstSid, upstreamSid, downstreamSid };
}

let C = null;
let chainError = null;
try { C = chain({ detail: true }); } catch (e) { chainError = e; }
const needChain = () => {
  if (!C) throw new Error(`chain fixture unavailable: ${chainError && chainError.message}`);
  return C;
};

caseBegin("resolver-names-every-stage-after-first-session-id", "hooks/workflow-state/plan-artifact-owner.js");
{
  const owner = (sid, stage) => F.mod("hooks/workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, stage);
  check("U1: downstream intent resolves to <first>-intent.md (no plan in the middle generation)", () => {
    const { firstSid, downstreamSid } = needChain();
    const r = owner(downstreamSid, "intent");
    return r && samePath(r.path, planOf(firstSid, "intent")) && r.ownerSid === firstSid && r.exists === true
      ? undefined : `got=${show(r)}`;
  });
  check("U1: downstream detail (first file, no approval record) resolves to <first>-detail.md", () => {
    const { firstSid, downstreamSid } = needChain();
    const r = owner(downstreamSid, "detail");
    return r && samePath(r.path, planOf(firstSid, "detail")) && r.ownerSid === firstSid && r.exists === true
      ? undefined : `got=${show(r)}`;
  });
  check("U1: downstream outline (no file anywhere) resolves to <first>-outline.md, exists=false", () => {
    const { firstSid, downstreamSid } = needChain();
    const r = owner(downstreamSid, "outline");
    return r && samePath(r.path, planOf(firstSid, "outline")) && r.ownerSid === firstSid && r.exists === false
      ? undefined : `got=${show(r)}`;
  });
  check("U1: the session-upstream (middle generation) also resolves to <first>-outline.md", () => {
    const { firstSid, upstreamSid } = needChain();
    const r = owner(upstreamSid, "outline");
    return r && samePath(r.path, planOf(firstSid, "outline")) ? undefined : `got=${show(r)}`;
  });
  check("U1: the first generation still resolves its own <first>-intent.md", () => {
    const { firstSid } = needChain();
    const r = owner(firstSid, "intent");
    return r && samePath(r.path, planOf(firstSid, "intent")) && r.exists === true ? undefined : `got=${show(r)}`;
  });
}
caseEnd();

caseBegin("plan-artifact-path-prints-first-session-path-for-writers", "bin/plan-artifact-path");
{
  const run = (args) => spawnSync(process.execPath, [path.join(F.ROOT, "bin", "plan-artifact-path")].concat(args),
    { cwd: neutral, env: childEnv(), encoding: "utf8", timeout: 60000 });
  check("U2: --session <downstream> --stage outline (file missing) prints <first>-outline.md, exit 0", () => {
    const { firstSid, downstreamSid } = needChain();
    const r = run(["--session", downstreamSid, "--stage", "outline"]);
    return r.status === 0 && samePath(String(r.stdout).trim(), planOf(firstSid, "outline"))
      ? undefined : `exit=${r.status} stdout=${show(r.stdout)} stderr=${show(r.stderr)}`;
  });
  check("U2: an invalid session id exits 1 with nothing on stdout", () => {
    const r = run(["--session", "bad.sid", "--stage", "intent"]);
    return r.status === 1 && String(r.stdout).trim() === "" ? undefined : `exit=${r.status} stdout=${show(r.stdout)}`;
  });
}
caseEnd();

// The writers below must ask bin/plan-artifact-path instead of building a plan path themselves.
caseBegin("writers-no-longer-build-plan-paths-from-own-sid", "bin/plan-artifact-path");
{
  const WRITERS = [
    "skills/clarify-intent/SKILL.md",
    "skills/clarify-intent/scripts/run-completion.sh",
    "skills/make-outline-plan/SKILL.md",
    "skills/make-outline-plan/scripts/run-codex-review-loop.sh",
    "skills/make-detail-plan/SKILL.md",
    "skills/make-detail-plan/scripts/run-codex-review-loop.sh",
    "skills/review-tests/scripts/run-codex-review-loop.sh",
    "skills/review-plan-security/SKILL.md",
    "skills/issue-create/SKILL.md",
    "skills/session-close/SKILL.md",
    "agents/outline-planner.md",
    "agents/detail-planner.md",
    "rules/github-issues.md",
    "bin/resolve-accepted-tradeoffs-file",
    "bin/github-issues/clarify-commit-scope.sh",
    "skills/worktree-start/scripts/derive-worktree-name.sh",
  ];
  const OWN_SID_PLAN = /\$\{?(SESSION_ID|SID|sid)\}?-(intent|outline|detail)\.md|<session-id>-(intent|outline|detail)\.md/;
  for (const rel of WRITERS) {
    check(`U3: ${rel} builds no plan path from its own session id`, () => {
      const abs = path.join(F.ROOT, ...rel.split("/"));
      if (!fs.existsSync(abs)) return `missing file ${rel}`;
      const hits = fs.readFileSync(abs, "utf8").split(/\r?\n/)
        .map((line, i) => [i + 1, line]).filter(([, line]) => OWN_SID_PLAN.test(line));
      return hits.length === 0 ? undefined : hits.slice(0, 3).map(([n, l]) => `${n}: ${l.trim().slice(0, 120)}`).join(" | ");
    });
  }
}
caseEnd();

caseBegin("approval-artifact-path-is-first-session-path", "hooks/lib/presentation-receipt.js");
{
  check("U4: approvalArtifactPath(downstream, intent) is <first>-intent.md", () => {
    const { firstSid, downstreamSid } = needChain();
    const got = F.mod("hooks/lib/presentation-receipt").approvalArtifactPath(downstreamSid, "intent");
    return samePath(got, planOf(firstSid, "intent")) ? undefined : `got=${show(got)}`;
  });
  check("U4: approvalArtifactPath(first, intent) stays <first>-intent.md", () => {
    const { firstSid } = needChain();
    const got = F.mod("hooks/lib/presentation-receipt").approvalArtifactPath(firstSid, "intent");
    return samePath(got, planOf(firstSid, "intent")) ? undefined : `got=${show(got)}`;
  });
}
caseEnd();

caseBegin("intent-glossary-loads-from-first-session-intent", "bin/lib/glossary-provenance.js");
{
  const load = (sid) => F.mod("bin/lib/glossary-provenance").loadIntentGlossary(sid);
  const rowsOk = (r) => r && r.ok === true && Array.isArray(r.rows) && r.rows.length === 1;
  check("U5: the first generation reads its own intent with its own approval record", () => {
    const { firstSid } = needChain();
    const r = load(firstSid);
    return rowsOk(r) ? undefined : `got=${show(r)}`;
  });
  check("U5: the session-downstream reads <first>-intent.md with the record naming first_session_id", () => {
    const { downstreamSid } = needChain();
    const r = load(downstreamSid);
    return rowsOk(r) ? undefined : `got=${show(r)}`;
  });
  check("U5: the downstream's approval sha is the first generation's", () => {
    const { firstSid, downstreamSid } = needChain();
    const a = load(firstSid);
    const b = load(downstreamSid);
    return a && b && a.approvalSha && a.approvalSha === b.approvalSha ? undefined : `first=${show(a)} downstream=${show(b)}`;
  });
}
caseEnd();

caseBegin("relint-resolves-first-session-artifact", "hooks/lib/plan-artifact-lang.js");
{
  check("U6: relintPlanArtifact(downstream, intent).artifactPath is <first>-intent.md", () => {
    const { firstSid, downstreamSid } = needChain();
    const r = F.mod("hooks/lib/plan-artifact-lang").relintPlanArtifact(downstreamSid, "intent");
    return r && samePath(r.artifactPath, planOf(firstSid, "intent")) ? undefined : `got=${show(r && r.artifactPath)} skipped=${show(r && r.skipped)}`;
  });
  check("U6: relintPlanArtifact(first, intent).artifactPath stays <first>-intent.md", () => {
    const { firstSid } = needChain();
    const r = F.mod("hooks/lib/plan-artifact-lang").relintPlanArtifact(firstSid, "intent");
    return r && samePath(r.artifactPath, planOf(firstSid, "intent")) ? undefined : `got=${show(r && r.artifactPath)}`;
  });
}
caseEnd();

// #2811 receipt mark API (continuedAt / carryMark / isContinued / markContinued).
const PRM = () => F.mod("hooks/lib/presentation-receipt");
const markFields = (sha) => ({ absPath: path.join(SCRATCH, "plan-2811.md"), link: { kind: "url", value: "https://example.test/p" }, contentSha: sha || "sha-a", anchorUuid: "a1" });
const rawReceipt = (sid) => JSON.parse(fs.readFileSync(PRM().receiptPath(sid, "outline"), "utf8"));
const tmpLeft = (sid) => fs.readdirSync(path.dirname(PRM().receiptPath(sid, "outline"))).filter((n) => n.startsWith(`${sid}.confirm-plan-receipt-outline`) && n.endsWith(".tmp"));
// Runs fn with fs.writeFileSync wrapped so that `after` fires once, right after the receipt tmp file is written.
function afterTmpWrite(after, fn) {
  const orig = fs.writeFileSync;
  let fired = false;
  fs.writeFileSync = function (file, ...rest) {
    const out = orig.call(this, file, ...rest);
    if (!fired && typeof file === "string" && file.endsWith(".tmp") && file.includes("confirm-plan-receipt-")) { fired = true; after(); }
    return out;
  };
  try { return fn(); } finally { fs.writeFileSync = orig; }
}

caseBegin("receipt-continued-mark-api", "hooks/lib/presentation-receipt.js");
{
  check("mark: a receipt without continuedAt reads ok, is not continued, and matches", () => {
    const sid = crypto.randomUUID();
    if (!PRM().writeReceipt(sid, "outline", markFields())) return "writeReceipt failed";
    const r = PRM().readReceipt(sid, "outline");
    return r.ok && !PRM().isContinued(r.receipt) && PRM().matchReceipt(r.receipt, markFields()).ok ? undefined : `got=${show(r)}`;
  });
  check("mark: a receipt carrying continuedAt reads ok, is continued, and still matches", () => {
    const sid = crypto.randomUUID();
    PRM().writeReceipt(sid, "outline", markFields());
    const body = Object.assign(rawReceipt(sid), { continuedAt: new Date().toISOString() });
    fs.writeFileSync(PRM().receiptPath(sid, "outline"), JSON.stringify(body));
    const r = PRM().readReceipt(sid, "outline");
    return r.ok && PRM().isContinued(r.receipt) && PRM().matchReceipt(r.receipt, markFields()).ok ? undefined : `got=${show(r)}`;
  });
  check("mark: isContinued is false for an empty or non-string continuedAt", () => {
    const f = PRM().isContinued;
    return typeof f === "function" && !f({ continuedAt: "" }) && !f({ continuedAt: 5 }) && !f({}) ? undefined : "isContinued missing or too lax";
  });
  check("mark: markContinued stamps the receipt and keeps every other field", () => {
    const sid = crypto.randomUUID();
    PRM().writeReceipt(sid, "outline", markFields());
    const before = rawReceipt(sid);
    if (PRM().markContinued(sid, "outline") !== true) return "markContinued did not return true";
    const after = rawReceipt(sid);
    const same = ["absPath", "contentSha", "anchorUuid", "writtenAt"].every((k) => after[k] === before[k]) && show(after.link) === show(before.link);
    return same && typeof after.continuedAt === "string" && after.continuedAt !== "" ? undefined : `after=${show(after)}`;
  });
  check("mark: markContinued on an absent receipt returns false and creates nothing", () => {
    const sid = crypto.randomUUID();
    return PRM().markContinued(sid, "outline") === false && !fs.existsSync(PRM().receiptPath(sid, "outline")) ? undefined : "created or true";
  });
  const carried = (sid, sha, carry) => {
    PRM().writeReceipt(sid, "outline", Object.assign(markFields(sha), { carryMark: carry }));
    return rawReceipt(sid).continuedAt;
  };
  for (const [name, sha, carry, want] of [
    ["carryMark=true with the same identity keeps continuedAt", "sha-a", true, true],
    ["carryMark=false drops continuedAt", "sha-a", false, false],
    ["carryMark=true with a changed contentSha drops continuedAt", "sha-b", true, false],
  ]) {
    check(`carry: ${name}`, () => {
      const sid = crypto.randomUUID();
      PRM().writeReceipt(sid, "outline", markFields());
      PRM().markContinued(sid, "outline");
      const mark = rawReceipt(sid).continuedAt;
      const got = carried(sid, sha, carry);
      return (want ? got === mark && typeof mark === "string" : got === undefined) ? undefined : `mark=${show(mark)} got=${show(got)}`;
    });
  }
}
caseEnd();

caseBegin("receipt-mark-race-with-consume-or-replace", "hooks/lib/presentation-receipt.js");
{
  check("t: a receipt consumed between read and rename is not resurrected (false, no tmp)", () => {
    const sid = crypto.randomUUID();
    PRM().writeReceipt(sid, "outline", markFields());
    const got = afterTmpWrite(() => PRM().consumeReceipt(sid, "outline"), () => PRM().markContinued(sid, "outline"));
    return got === false && !fs.existsSync(PRM().receiptPath(sid, "outline")) && tmpLeft(sid).length === 0 ? undefined : `got=${show(got)} tmp=${show(tmpLeft(sid))}`;
  });
  check("u: a receipt replaced with another contentSha is left as replaced (false, no tmp)", () => {
    const sid = crypto.randomUUID();
    PRM().writeReceipt(sid, "outline", markFields());
    const swapped = Object.assign(rawReceipt(sid), { contentSha: "sha-swapped" });
    const got = afterTmpWrite(() => fs.writeFileSync(PRM().receiptPath(sid, "outline"), JSON.stringify(swapped)), () => PRM().markContinued(sid, "outline"));
    const now = rawReceipt(sid);
    return got === false && now.contentSha === "sha-swapped" && now.continuedAt === undefined && tmpLeft(sid).length === 0 ? undefined : `got=${show(got)} now=${show(now)}`;
  });
}
caseEnd();

caseBegin("upstream-view-intent-is-first-session-path", "bin/lib/resume-session/upstream-view.js");
{
  check("U7: buildUpstreamView with a session-upstream that is itself a downstream names <first>-intent.md", () => {
    const { firstSid, upstreamSid, downstreamSid } = needChain();
    const view = F.mod("bin/lib/resume-session/upstream-view").buildUpstreamView({ heirSid: downstreamSid, upstreamSid });
    const got = view && view.artifacts ? view.artifacts.intent : undefined;
    return samePath(got, planOf(firstSid, "intent")) ? undefined : `artifacts.intent=${show(got)} availability=${show(view && view.availability)}`;
  });
}
caseEnd();
