"use strict";
// hooks/lib/plan-link.js
// The one place that turns a plan artifact into its model-facing line: the blob URL plus the
// local path when the plan may be shown by URL, otherwise the local path plus a reason word.
// show-plan-link.js, confirm-checkpoint.js, the Stop guard's plan-link check and bin/plan-link
// share it, so they never disagree on "published". Whether a URL may be shown follows the
// project-host record beside the plan (hooks/lib/plan-sync/project-host.js).
const fs = require("fs");
const path = require("path");
const { toWindowsPath } = require("./branch-diff");

const REASONS = Object.freeze({
  NO_ARTIFACT: "no-artifact",
  PLAN_SYNC_OFF: "plan-sync-off",
  NOT_PROVISIONED: "not-provisioned",
  NOT_PUBLISHED: "not-published",
  UNKNOWN_FORGE: "unknown-forge",
  HOST_MISMATCH: "host-mismatch",
  NO_PROJECT_HOST: "no-project-host",
  INVALID_SESSION: "invalid-session",
});

const STAGES = Object.freeze(["intent", "outline", "detail"]);

// The command the model runs to look a plan up later. Only this file spells it (CPR-SSOT).
const PLAN_LINK_COMMAND = 'node "$AGENTS_MAIN_ROOT/bin/plan-link" --stage <stage>';

// A Claude Code session id is a UUID; clarify-intent falls back to YYYYMMDD-HHMMSS without one.
const SESSION_ID_RE = /^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{8}-\d{6})$/i;

// What each reason means to the model, and what (if anything) changes it.
const REASON_TEXT = Object.freeze({
  [REASONS.NO_ARTIFACT]: "no plan file for this stage yet",
  [REASONS.PLAN_SYNC_OFF]: "plan-sync is not configured (PLAN_SYNC_REMOTE_URL empty), so there is no URL",
  [REASONS.NOT_PROVISIONED]: "plan-sync is not provisioned on this machine; the user can run bin/plan-sync-init",
  [REASONS.NOT_PUBLISHED]: "the current content is not on the plan remote yet",
  [REASONS.UNKNOWN_FORGE]: "the plan remote is on no known forge, so no blob URL can be built",
  [REASONS.HOST_MISMATCH]: "the project's host differs from the plan remote's host, so the plan is not sent",
  [REASONS.NO_PROJECT_HOST]: "the project's host is unknown (no origin or not a git repository), so the plan is not sent",
  [REASONS.INVALID_SESSION]: "the session id is not usable",
});

const REASON_VALUES = Object.values(REASONS);
// Sync-result reasons that carry over to the link unchanged.
const CARRIED_SYNC_REASONS = new Set([REASONS.HOST_MISMATCH, REASONS.NO_PROJECT_HOST, REASONS.UNKNOWN_FORGE]);

// linkFromSyncResult(result) -> {url} | {reason} — maps one syncPlanFile result.
function linkFromSyncResult(result) {
  const r = result && typeof result === "object" ? result : {};
  if (r.status === "pushed" && typeof r.url === "string" && r.url) return { url: r.url };
  if (r.status === "pushed") return { reason: REASONS.UNKNOWN_FORGE };
  if (r.status === "off") return { reason: REASONS.PLAN_SYNC_OFF };
  if (r.status === "not-provisioned") return { reason: REASONS.NOT_PROVISIONED };
  if (r.status === "skipped" && CARRIED_SYNC_REASONS.has(r.reason)) return { reason: r.reason };
  return { reason: REASONS.NOT_PUBLISHED };
}

function isRegularFile(p) {
  try { return fs.lstatSync(p).isFile(); } catch (_) { return false; }
}

function isSessionId(sid) {
  return typeof sid === "string" && SESSION_ID_RE.test(sid);
}

// linkOf(plansDir, absPath) -> {url} | {reason}, for a plan file known to exist.
function linkOf(plansDir, absPath) {
  try {
    const PS = require("./plan-sync");
    const env = PS.resolveRemoteUrl();
    if (!env.value || env.loadFailed) return { reason: REASONS.PLAN_SYNC_OFF };
    const cp = PS.checkProvisioned(plansDir, env.value);
    if (!cp.ok) return { reason: REASONS.NOT_PROVISIONED };
    const state = PS.readProjectHostState(absPath, cp.pushUrl);
    if (state === REASONS.HOST_MISMATCH || state === REASONS.NO_PROJECT_HOST) return { reason: state };
    if (PS.resolveRemoteTarget(cp.pushUrl).type === "unknown") return { reason: REASONS.UNKNOWN_FORGE };
    const url = PS.publishedBlobUrl(plansDir, absPath);
    return url ? { url } : { reason: REASONS.NOT_PUBLISHED };
  } catch (_) {
    return { reason: REASONS.NOT_PUBLISHED };
  }
}

// resolvePlanLink(sid, stage, {plansDir?, absPath?}) -> {url?, path?, reason?}.
// Read-only and network-free. An existing plan file always yields its absolute path.
function resolvePlanLink(sid, stage, opts) {
  if (!isSessionId(sid)) return { reason: REASONS.INVALID_SESSION };
  if (!STAGES.includes(stage)) return { reason: REASONS.NO_ARTIFACT };
  let plansDir;
  try {
    const o = opts || {};
    plansDir = toWindowsPath(o.plansDir || require("./workflow-plans-dir").getWorkflowPlansDir());
    // Owner-resolved: a downstream session's plan is its upstream's file (#2633).
    const abs = o.absPath ||
      require("../workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, stage, undefined, { plansDir }).path;
    return linkForFile(abs, { plansDir });
  } catch (_) {
    return { reason: REASONS.NO_ARTIFACT };
  }
}

// linkForFile(absPath, {plansDir?}) -> {url?, path?, reason?} for a plan file the caller already
// holds (the after-write hook), so no session id is needed to name it.
function linkForFile(absPath, opts) {
  let plansDir;
  let abs;
  try {
    const o = opts || {};
    plansDir = toWindowsPath(o.plansDir || require("./workflow-plans-dir").getWorkflowPlansDir());
    abs = path.resolve(toWindowsPath(absPath));
  } catch (_) {
    return { reason: REASONS.NO_ARTIFACT };
  }
  if (!isRegularFile(abs)) return { reason: REASONS.NO_ARTIFACT };
  return { path: abs, ...linkOf(plansDir, abs) };
}

// entryLine({stage, url?, path?, reason?}) -> one line, shared by the hooks and the CLI.
// The local path is inline code so it is never a second, mistappable link beside the URL on
// mobile; the URL stays bare so the reply auto-links it.
function entryLine(entry) {
  const e = entry || {};
  const stage = STAGES.includes(e.stage) ? e.stage : "plan";
  const p = typeof e.path === "string" && e.path ? e.path : "";
  if (typeof e.url === "string" && /^https?:\/\//.test(e.url)) return p ? `${stage}: ${e.url} (\`${p}\`)` : `${stage}: ${e.url}`;
  const reason = REASON_VALUES.includes(e.reason) ? e.reason : REASONS.NOT_PUBLISHED;
  return p ? `${stage}: \`${p}\` (no URL: ${reason})` : `${stage}: (unavailable: ${reason})`;
}

// renderModelContext(entries, {when: "after-write" | "confirm"}) -> additionalContext text.
function renderModelContext(entries, opts) {
  const list = Array.isArray(entries) ? entries : [];
  const confirm = Boolean(opts && opts.when === "confirm");
  const lines = [confirm ? "[plan-link] The plan being confirmed:" : "[plan-link] Plan artifact written:"];
  // The reason's meaning rides its own entry line, so each reason word appears once per plan.
  for (const e of list) {
    const line = entryLine(e);
    const hasUrl = e && typeof e.url === "string" && /^https?:\/\//.test(e.url);
    const reason = e && REASON_VALUES.includes(e.reason) ? e.reason : REASONS.NOT_PUBLISHED;
    lines.push(hasUrl ? line : `${line} — ${REASON_TEXT[reason]}`);
  }
  lines.push(confirm
    ? "End the final body text of the presentation turn with each line above as-is and close the turn; the CONFIRM echo comes in a later turn, after the user's reply, and never carries the line."
    : "End the final body text of this turn with each line above as-is and close the turn so the user can open the plan; the CONFIRM echo comes after the user's reply.");
  lines.push(`When asked later where a plan is, run ${PLAN_LINK_COMMAND} and write its output as-is; never send the plan with SendUserFile.`);
  return lines.join("\n");
}

module.exports = {
  REASONS,
  STAGES,
  REASON_TEXT,
  PLAN_LINK_COMMAND,
  SESSION_ID_RE,
  isSessionId,
  linkFromSyncResult,
  resolvePlanLink,
  linkForFile,
  entryLine,
  renderModelContext,
};
