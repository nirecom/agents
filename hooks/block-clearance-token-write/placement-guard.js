// hooks/block-clearance-token-write/placement-guard.js
// Placement guard (#2434 D7b, #1814): (b) any write under the workflow dir (control dirs,
// every <sid>.json, other sessions' files), (c) unregistered or control-kind session files in WORKFLOW_PLANS_DIR.
// Both lift under WORKFLOW=off; (a) markers and tokens stay with classifyProtectedPath.
"use strict";

const path = require("path");
const { parse } = require("../lib/command-ir");
const { toWindowsPath } = require("../lib/branch-diff");
const { collectDetectionTargets } = require("../lib/bash-write-targets/detection-targets");
const { expandForDetection } = require("../lib/bash-write-targets/detection-expand");
const { classifyProtectedPath } = require("../lib/protected-basenames");
const { extractSubstitutionContents } = require("../lib/command-parser");
const { priorAssignmentsText } = require("./bash-scan/assignment-text");
const { nestedCommandTextsOf, stdinProgramRoutes } = require("./nested-bodies");
const {
  candidateTargets,
  interpreterVerdict,
  languageBodyWrites,
  mentionsWorkflowDir,
} = require("./placement-guard/bash-candidates");

const STATE_DIRS_DOC = "docs/architecture/claude-code/state-dirs.md";
const CANONICAL_ROUTES = [
  "Canonical routes: review loops are wrapper-managed (the wrapper owns round numbers and terminals);",
  "  exit-6 residual accept: bin/accept-exit6-residual; worker payloads: bin/worker-dispatch-payload;",
  "  risk signals: bin/record-risk-signal; stuck: skills/_shared/codex-review-loop/exit-codes.md \"Escalation by format\".",
  "Scratch notes belong in <sid>-note-<topic>.<ext> under WORKFLOW_PLANS_DIR, or in the session scratchpad.",
  "WORKFLOW=off allows it (the placement guard lifts; clearance tokens and markers stay protected).",
];
const PLACEMENT_MESSAGES = Object.freeze({
  "control-dir": [
    "Direct write under the workflow dir (<WORKFLOW_STATE_DIR>: <sid>.control/, <sid>.json, any session's files) blocked.",
    `Control files are written only by the owning CLIs and hooks; see ${STATE_DIRS_DOC}.`,
    ...CANONICAL_ROUTES,
  ].join("\n"),
  "plans-unregistered": [
    "Write of an unregistered or control-kind session file in WORKFLOW_PLANS_DIR blocked.",
    `WORKFLOW_PLANS_DIR holds registered prose artifacts only; control files moved to the control dir (${STATE_DIRS_DOC}).`,
    ...CANONICAL_ROUTES,
  ].join("\n"),
  "alias-unresolved": [
    "Write through an unresolvable WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR / HOME expansion blocked.",
    `The target cannot be placed, so it may land in the control dir or the plans dir (${STATE_DIRS_DOC}).`,
    "Spell the path with a plain $VAR, ${VAR} or ${VAR:-default}, or write it literally.",
    ...CANONICAL_ROUTES,
  ].join("\n"),
});

function fold(p) {
  const r = path.resolve(toWindowsPath(p)).replace(/\\/g, "/").replace(/\/+$/, "");
  return process.platform === "win32" ? r.toLowerCase() : r;
}

function relUnder(abs, dir) {
  if (!dir) return null;
  const d = fold(dir);
  return abs.startsWith(`${d}/`) ? abs.slice(d.length + 1) : null;
}

function workflowDir() {
  try { return require("../workflow-state").getWorkflowDir(); } catch (_) { return null; }
}
function plansDir() {
  try { return require("../lib/workflow-plans-dir").getWorkflowPlansDir(); } catch (_) { return null; }
}

// Lazy: the wsid resolver spawns git, so it runs only for a plans entry nothing else placed.
function resolveWsid() {
  try { return require("../lib/resolve-workflow-session-id").resolveWorkflowSessionId(); } catch (_) { return null; }
}

function classifyPlansName(name, ctx) {
  const { classifyPlansEntry } = require("../lib/plans-artifact-registry");
  const verdict = classifyPlansEntry(name, { sid: ctx.sid, wsid: ctx.wsid });
  if (verdict === "control" || verdict === "ambiguous" || verdict === "unregistered") return "plans-unregistered";
  if (verdict !== "no-sid" || ctx.wsid !== undefined) return null;
  const wsid = resolveWsid();
  return wsid && name.startsWith(`${wsid}-`) ? "plans-unregistered" : null;
}

function classifyPlacement(absPath, ctx) {
  const c = ctx || {};
  if (c.workflowOff || typeof absPath !== "string" || absPath === "") return null;
  const abs = fold(absPath);
  if (relUnder(abs, workflowDir()) !== null) return "control-dir";
  const inPlans = relUnder(abs, plansDir());
  if (inPlans === null || inPlans.includes("/")) return null;
  return classifyPlansName(path.basename(absPath.replace(/[\\/]+$/, "")), c);
}

// A dynamic tail is placed only when its static prefix already sits inside the workflow dir.
function dynamicPrefixKind(prefix, cwd) {
  const wf = workflowDir();
  if (!prefix || !wf) return null;
  const abs = fold(path.resolve(cwd, prefix));
  const inside = relUnder(abs, wf) !== null || (abs === fold(wf) && /[\\/]$/.test(prefix));
  return inside ? "control-dir" : null;
}

// classifySpelling(spelling, env): the verdict for ONE candidate spelling of a write target.
function classifySpelling(spelling, env) {
  const d = expandForDetection(spelling);
  if (d.aliasUnresolved) {
    const tailKind = classifyProtectedPath(path.basename(d.tail || ""), { sessionCtx: env.o.sessionCtx });
    if (tailKind) return tailKind;
    return env.workflowOff ? null : "alias-unresolved";
  }
  if (env.workflowOff) return null;
  if (d.dynamicTail) return dynamicPrefixKind(d.path, env.cwd);
  if (!d.path) return null;
  return classifyPlacement(path.resolve(env.cwd, d.path), env.ctx);
}

// Nested command text (substitutions, eval / here-string bodies, shell -c bodies)
// is re-classified as command text, capped like bash-scan's MAX_NESTED_SCAN_DEPTH.
const MAX_PLACEMENT_DEPTH = 3;

function classifyBashPlacement(cmd, opts, _depth) {
  const o = opts || {};
  const depth = typeof _depth === "number" ? _depth : 0;
  const text = String(cmd || "");
  const workflowOff = o.workflowOff === true;
  const ir = parse(text);
  if (!ir || ir.parseFailure) return null;
  const cwd = o.cwd ? toWindowsPath(o.cwd) : process.cwd();
  const env = { o, cwd, workflowOff, ctx: { sid: o.sid, wsid: o.wsid, workflowOff } };
  const wf = workflowOff ? null : workflowDir();
  const foldedWf = wf ? fold(wf) : null;
  const recurse = (t) => (depth < MAX_PLACEMENT_DEPTH ? classifyBashPlacement(t, o, depth + 1) : null);
  if (foldedWf) {
    for (const sub of extractSubstitutionContents(text)) {
      const k = recurse(sub);
      if (k) return k;
    }
  }
  const segments = ir.segments || [];
  for (let idx = 0; idx < segments.length; idx++) {
    const seg = segments[idx];
    if (!seg) continue;
    const assignText = `${priorAssignmentsText(segments, idx)}\n${seg.rawText || ""}`;
    for (const raw of collectDetectionTargets([seg])) {
      const { list, overCap } = candidateTargets(raw, assignText);
      if (overCap && foldedWf && mentionsWorkflowDir(raw, foldedWf)) return "control-dir";
      for (const spelling of list) {
        const kind = classifySpelling(spelling, env);
        if (kind) return kind;
      }
    }
    if (!foldedWf) continue;
    for (const body of nestedCommandTextsOf(seg)) {
      const k = recurse(body);
      if (k) return k;
    }
    const ik = interpreterVerdict(seg.rawText || "", foldedWf, recurse);
    if (ik) return ik;
  }
  if (foldedWf) {
    for (const b of stdinProgramRoutes(text, segments).bodies) {
      if (languageBodyWrites(b.body, b.lang, foldedWf)) return "control-dir";
    }
  }
  return null;
}

module.exports = { PLACEMENT_MESSAGES, classifyPlacement, classifyBashPlacement };
