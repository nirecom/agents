#!/usr/bin/env node
"use strict";
// Tests: bin/resume-session-detect, hooks/progress-nudge.js, hooks/lib/progress-file.js, bin/progress-file, bin/plan-artifact-path
// Tags: TL2, session-inherit, progress-file, progress-nudge, regression-2748, scope:issue-specific, pwsh-not-required, plan-artifact
// #2748 E2E1: the real path end to end. B adopts A through `resume-session-detect --from A`, then
// the progress-nudge hook runs for B at Stop. The progress file stays the first generation's
// (<A>-session-progress.md); no split <B>-session-progress.md appears and B's sidecar carries no
// root_sid pin. E2E2: a later step completion in B is nudged with A's file named. Every child runs from a neutral temp HOME with CLAUDE_CODE_SESSION_ID set only
// where the CLI needs the heir's id.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2748-e2e-"));
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
    if (typeof why === "string") assert.fail(why);
  });
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
const samePath = (a, b) => {
  const n = (p) => path.resolve(String(p || "")).replace(/\\/g, "/").toLowerCase();
  return n(a) === n(b);
};

const home = fs.mkdtempSync(path.join(SCRATCH, "home-"));
const tbase = fs.mkdtempSync(path.join(SCRATCH, "transcripts-"));
function childEnv(sessionId) {
  const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home, CLAUDE_TRANSCRIPT_BASE_DIR: tbase });
  delete env.CLAUDE_CODE_SESSION_ID;
  if (sessionId) env.CLAUDE_CODE_SESSION_ID = sessionId;
  return env;
}
const progressOf = (sid) => path.join(PLANS, `${sid}-session-progress.md`);
const sidecarOf = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`, "progress-pressure.json");

caseBegin("resume-then-nudge-keeps-first-generation-progress", "hooks/progress-nudge.js");
{
  const A = "f2748-e2e-a";
  const B = "f2748-e2e-b";
  const CTX = { cwd: "/fixture/f2748-e2e/repo", git_branch: "feature/f2748-e2e" };
  const io = F.S();
  io.writeState(A, io.createInitialState(A, CTX));
  io.markStep(A, "workflow_init", "complete");
  fs.writeFileSync(path.join(PLANS, `${A}-intent.md`), "**Title:** f2748 e2e\n");
  io.writeState(B, io.createInitialState(B, CTX));

  const adopt = spawnSync(process.execPath, [path.join(F.ROOT, "bin", "resume-session-detect"), "--from", A],
    { cwd: home, env: childEnv(B), encoding: "utf8", timeout: 60000 });
  let ir = null;
  try { ir = JSON.parse(adopt.stdout).inherit_result; } catch (_) { ir = null; }
  check("E2E1: resume-session-detect --from A adopts A into B", () => (adopt.status === 0 && ir && ir.ok === true
    ? undefined : `exit=${adopt.status} inherit_result=${show(ir)} stderr=${show(adopt.stderr)}`));

  const transcript = path.join(tbase, `${B}.jsonl`);
  fs.writeFileSync(transcript, '{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-01-01T00:00:01Z"}\n');
  const nudge = spawnSync(process.execPath, [path.join(F.ROOT, "hooks", "progress-nudge.js")], {
    cwd: home, env: childEnv(null), encoding: "utf8", timeout: 60000,
    input: JSON.stringify({ session_id: B, transcript_path: transcript, hook_event_name: "Stop", stop_hook_active: false }),
  });
  check("E2E1: the progress-nudge hook exits 0", () => (nudge.status === 0 ? undefined : `exit=${nudge.status} stderr=${show(nudge.stderr)}`));
  check("E2E1: <A>-session-progress.md exists", () => (fs.existsSync(progressOf(A)) ? undefined : `missing; plans=${show(fs.readdirSync(PLANS))}`));
  check("E2E1: no split <B>-session-progress.md was created", () => (fs.existsSync(progressOf(B)) ? `found ${progressOf(B)}` : undefined));
  check("E2E1: B's sidecar carries no root_sid key", () => {
    let side = null;
    try { side = JSON.parse(fs.readFileSync(sidecarOf(B), "utf8")); } catch (_) { side = null; }
    return side && Object.prototype.hasOwnProperty.call(side, "root_sid") ? `sidecar=${show(side)}` : undefined;
  });
  const cli = spawnSync(process.execPath, [path.join(F.ROOT, "bin", "progress-file"), "path", "--session", B],
    { cwd: home, env: childEnv(null), encoding: "utf8", timeout: 60000 });
  check("E2E1: bin/progress-file path --session B names A's file", () => (cli.status === 0 && samePath(String(cli.stdout).trim(), progressOf(A))
    ? undefined : `exit=${cli.status} stdout=${show(cli.stdout)} stderr=${show(cli.stderr)}`));
  check("E2E1: progressPathFor(B) is the first generation's progress file", () => {
    const got = F.mod("hooks/lib/progress-file").progressPathFor(B);
    return got && samePath(got, progressOf(A)) ? undefined : `progressPathFor=${show(got)}`;
  });
}
caseEnd();

// E2E2: after the same real --from inheritance, a new step completion in B makes the nudge hook
// ask for an update, and the request names A's progress file, not B's.
caseBegin("resume-then-step-complete-nudge-names-first-generation-file", "hooks/progress-nudge.js");
{
  const A = "f2748-e2e2-a";
  const B = "f2748-e2e2-b";
  const CTX = { cwd: "/fixture/f2748-e2e2/repo", git_branch: "feature/f2748-e2e2" };
  const io = F.S();
  io.writeState(A, io.createInitialState(A, CTX));
  io.markStep(A, "workflow_init", "complete");
  fs.writeFileSync(path.join(PLANS, `${A}-intent.md`), "**Title:** f2748 e2e2\n");
  io.writeState(B, io.createInitialState(B, CTX));
  const adopt = spawnSync(process.execPath, [path.join(F.ROOT, "bin", "resume-session-detect"), "--from", A],
    { cwd: home, env: childEnv(B), encoding: "utf8", timeout: 60000 });
  let ir = null;
  try { ir = JSON.parse(adopt.stdout).inherit_result; } catch (_) { ir = null; }
  check("E2E2: resume-session-detect --from A adopts A into B", () => (adopt.status === 0 && ir && ir.ok === true
    ? undefined : `exit=${adopt.status} inherit_result=${show(ir)} stderr=${show(adopt.stderr)}`));

  const transcript = path.join(tbase, `${B}.jsonl`);
  fs.writeFileSync(transcript, Buffer.alloc(10 * 1024, 120));
  // bash(): one PostToolUse(Bash) through the real hook; returns its additionalContext ("" when silent).
  const bash = () => {
    const r = spawnSync(process.execPath, [path.join(F.ROOT, "hooks", "progress-nudge.js")], {
      cwd: home, env: childEnv(null), encoding: "utf8", timeout: 60000,
      input: JSON.stringify({ session_id: B, transcript_path: transcript, cwd: home, hook_event_name: "PostToolUse",
        tool_name: "Bash", tool_input: { command: "true" }, tool_response: {} }),
    });
    let j = null;
    try { j = JSON.parse(String(r.stdout).trim() || "{}"); } catch (_) { j = null; }
    const h = j && j.hookSpecificOutput;
    return h && typeof h.additionalContext === "string" ? h.additionalContext : "";
  };
  for (let i = 0; i < 3; i++) bash();
  io.markStep(B, "research", "complete");
  const ctx = bash();
  const fileLine = (ctx.split("\n").find((l) => l.startsWith("file: ")) || "").slice("file: ".length);
  check("E2E2: a new step completion in B makes the hook ask for an update naming it", () => (ctx.includes("[progress check]") && ctx.includes("step complete: research")
    ? undefined : `ctx=${show(ctx)}`));
  check("E2E2: the request names A's progress file", () => (fileLine && samePath(fileLine, progressOf(A)) ? undefined : `file=${show(fileLine)} ctx=${show(ctx)}`));
  check("E2E2: the request does not name B's progress file", () => (fileLine && !samePath(fileLine, progressOf(B)) ? undefined : `file=${show(fileLine)}`));
  check("E2E2: progressPathFor(B) is the first generation's progress file", () => {
    const got = F.mod("hooks/lib/progress-file").progressPathFor(B);
    return got && samePath(got, progressOf(A)) ? undefined : `progressPathFor=${show(got)}`;
  });
  const pap = spawnSync(process.execPath, [path.join(F.ROOT, "bin", "plan-artifact-path"), "--stage", "intent", "--session", B],
    { cwd: home, env: childEnv(null), encoding: "utf8", timeout: 60000 });
  check("E2E2: plan-artifact-path --stage intent for B prints <A>-intent.md", () => (pap.status === 0 && samePath(String(pap.stdout).trim(), path.join(PLANS, `${A}-intent.md`))
    ? undefined : `exit=${pap.status} stdout=${show(pap.stdout)} stderr=${show(pap.stderr)}`));
  const papOutline = spawnSync(process.execPath, [path.join(F.ROOT, "bin", "plan-artifact-path"), "--stage", "outline", "--session", B],
    { cwd: home, env: childEnv(null), encoding: "utf8", timeout: 60000 });
  check("E2E2: plan-artifact-path --stage outline for B (no file yet) prints <A>-outline.md", () => (papOutline.status === 0 && samePath(String(papOutline.stdout).trim(), path.join(PLANS, `${A}-outline.md`))
    ? undefined : `exit=${papOutline.status} stdout=${show(papOutline.stdout)} stderr=${show(papOutline.stderr)}`));
}
caseEnd();
