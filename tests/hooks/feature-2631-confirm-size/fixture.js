"use strict";
// Fixture for tests/hooks/feature-2631-confirm-size*.js: started sessions owning plan artifacts
// of an exact line count, CONFIRM_* config roots, and runners for hooks/confirm-checkpoint.js
// (PreToolUse, CONFIRM echo) and hooks/stop-confirm-plan-guard.js (Stop, Layer 2 transcript).
// The caller runs harness isolate() first; every CONFIRM_* / PLAN_LANG value reaches the child
// both through the config root's .env and through the child env, so neither source can drift.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const F = require("../feature-2631-size-limits/fixture");

const HARD = { intent: 200, outline: 200, detail: 500 };
const WARN = { intent: 100, outline: 100, detail: 300 };
const STEP = { intent: "clarify_intent", outline: "outline", detail: "detail" };
// The stage-valid follow-up skill Layer 2 looks for (hooks/workflow-state/plan-stage-table.js).
const FOLLOW = { intent: "make-outline-plan", outline: "make-detail-plan", detail: "write-tests" };
// The Japanese "send back to the planner" and a Japanese plan line are fixtures. lang-check: ignore
const SEND_BACK = "planner に差し戻す";
const JA_LINE = "この計画書は日本語で書かれています。\n";
const SIZE_PREFIX = "[confirm-plan] Layer 2/plan-size:";
const LANG_PREFIX = "[confirm-plan] Layer 2/plan-lang:";

let seq = 0;
const roots = {};
// cfg(name, vals) -> a config root whose .env carries vals; vals are also the child env pins.
function cfg(name, vals) {
  const dir = F.configRoot("confirm-" + name, Object.entries(vals).map(([k, v]) => `${k}=${v}`));
  roots[dir] = vals;
  return dir;
}
const ON = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", PLAN_LANG: "english", PLAN_SYNC_REMOTE_URL: "" };
let onRoot = null;
function onCfg() { return onRoot || (onRoot = cfg("on", ON)); }

function planPath(sid, stage) { return path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-${stage}.md`); }
function writePlan(sid, stage, text) {
  fs.writeFileSync(planPath(sid, stage), text);
  return planPath(sid, stage);
}
// planOf(n) -> a plan-lang clean artifact of exactly n lines (English prose, no heading to lint).
function planOf(n) { return F.proseLines(n); }

// session(stage, lines, opts) -> sid: a started session owning <sid>-<stage>.md of `lines` lines.
function session(stage, lines, opts) {
  const o = opts || {};
  const sid = F.newSid();
  F.writeStartedState(sid, o.top, o.events);
  if (lines != null) writePlan(sid, stage, planOf(lines));
  return sid;
}

function childEnv(root, over) {
  // CONV_LANG is pinned: the parent session's value would prefix every block reason (#2699).
  const env = Object.assign({}, process.env, { CONV_LANG: "english" }, roots[root] || {}, {
    AGENTS_MAIN_ROOT: root, CLAUDE_TRANSCRIPT_BASE_DIR: emptyDir(),
  }, over || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  return env;
}
function emptyDir() {
  const d = path.join(F.work(), "no-transcripts");
  fs.mkdirSync(d, { recursive: true });
  return d;
}
function parseLast(stdout) {
  try { return JSON.parse(String(stdout || "").trim().split("\n").pop()); } catch (_) { return null; }
}

// confirm / stop take opts.root: the checkout whose hook is spawned (default: this repo), so an
// SSOT-propagation case can run the hook of a copied tree with a rewritten size-limits.js, and
// opts.preload: a module the hook is started with (`node -r`), e.g. throw-preload.js. confirm
// also takes opts.input: fields that replace the hook input's (e.g. an empty transcript_path).
function hookArgv(o, hook) {
  const file = path.join(o.root || F.ROOT, "hooks", hook);
  return o.preload ? ["-r", o.preload, file] : [file];
}
// confirm(sid, stage, opts) -> {decision, deny, reason, ctx, msg, raw}. Unless opts.present is
// false, the plan is first "presented": present.js writes the #2729 receipt in the child env, so
// a deny here comes from the size check, or from a plan file that cannot be found.
function confirm(sid, stage, opts) {
  const o = opts || {};
  const env = childEnv(o.cfg || onCfg(), o.env);
  if (o.present !== false) {
    spawnSync(process.execPath, [path.join(__dirname, "present.js"), sid, stage], { encoding: "utf8", timeout: 60000, cwd: F.work(), env });
  }
  const input = {
    tool_name: "Bash", hook_event_name: "PreToolUse",
    tool_input: { command: `echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}: ok>>"` },
    session_id: sid, tool_use_id: `tu-${++seq}`,
    transcript_path: path.join(F.work(), "no-such-transcript.jsonl"),
    ...(o.input || {}),
  };
  const r = spawnSync(process.execPath, hookArgv(o, "confirm-checkpoint.js"), {
    input: JSON.stringify(input), encoding: "utf8", timeout: 60000, cwd: F.work(), env,
  });
  const out = parseLast(r.stdout) || {};
  const hso = out.hookSpecificOutput || {};
  return {
    decision: out.decision, deny: out.decision === "block" && hso.permissionDecision === "deny",
    reason: String(out.reason || ""), ctx: String(hso.additionalContext || ""), msg: String(out.systemMessage || ""),
    skipped: /\[confirm-skipped: /.test(String(out.systemMessage || "")),
    raw: `rc=${r.status} out=${r.stdout} err=${String(r.stderr || "").slice(0, 300)}`,
  };
}

// layer2Transcript(stage, followUp) -> a transcript whose last assistant entry is the CONFIRM
// echo followed by the stage-valid follow-up, so Layer 2 has nothing to say about a clean plan.
function layer2Transcript(stage, followUp) {
  const content = [{ type: "tool_use", id: "e1", name: "Bash", input: { command: `echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}: ok>>"` } }];
  if (followUp !== false) content.push({ type: "tool_use", id: "s1", name: "Skill", input: { skill: FOLLOW[stage] } });
  const tp = path.join(F.work(), `l2-${++seq}.jsonl`);
  fs.writeFileSync(tp, JSON.stringify({ type: "user", message: { role: "user", content: "go" } }) + "\n" +
    JSON.stringify({ type: "assistant", message: { role: "assistant", content } }) + "\n");
  return tp;
}

// stop(sid, tpath, opts) -> {rc, out, reason, raw}
function stop(sid, tpath, opts) {
  const o = opts || {};
  const input = { session_id: sid, transcript_path: tpath, hook_event_name: "Stop", stop_hook_active: false };
  const r = spawnSync(process.execPath, hookArgv(o, "stop-confirm-plan-guard.js"), {
    input: JSON.stringify(input), encoding: "utf8", timeout: 60000, cwd: F.work(), env: childEnv(o.cfg || onCfg(), o.env),
  });
  const out = String(r.stdout || "");
  const json = parseLast(out) || {};
  return {
    rc: r.status, out, reason: json.decision === "block" ? String(json.reason || "") : "",
    raw: `rc=${r.status} out=${out.slice(0, 300)} err=${String(r.stderr || "").slice(0, 200)}`,
  };
}
const quiet = (r) => r.rc === 0 && r.out.trim() === "";
const THROW_PRELOAD = path.join(__dirname, "throw-preload.js");
const blockedWith = (r, prefix, needles) => r.rc === 2 && r.reason.startsWith(prefix) &&
  (needles || []).every((n) => r.reason.includes(String(n)));

module.exports = {
  F, HARD, WARN, STEP, FOLLOW, SEND_BACK, JA_LINE, SIZE_PREFIX, LANG_PREFIX,
  cfg, onCfg, planPath, writePlan, planOf, session, confirm, layer2Transcript, stop, quiet, blockedWith, THROW_PRELOAD,
};
