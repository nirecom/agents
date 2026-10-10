"use strict";
// hooks/lib/plan-link.js
// The one place that turns a plan artifact into its model-facing link: the GitHub blob URL
// when the file is published, otherwise a reason code. Hooks (show-plan-link, confirm-checkpoint,
// the Stop guard's Layer 3) and bin/plan-link share it so they never disagree on "published".
// Model-facing output never carries a local absolute path, the plans dir, or ~/.workflow-plans:
// the plans dir is private to this machine, the blob URL is what the user can open.
const fs = require("fs");
const path = require("path");

const REASONS = Object.freeze({
  NO_ARTIFACT: "no-artifact",
  PLAN_SYNC_OFF: "plan-sync-off",
  NOT_PROVISIONED: "not-provisioned",
  NOT_PUBLISHED: "not-published",
  NON_GITHUB: "non-github",
  INVALID_SESSION: "invalid-session",
});

const STAGES = Object.freeze(["intent", "outline", "detail"]);

// Same shape the plans-artifact registry accepts; a sid never carries a separator or "..".
const SID_RE = /^[A-Za-z0-9_-]+$/;

// What each reason means to the model, and what (if anything) fixes it.
const REASON_TEXT = Object.freeze({
  [REASONS.NO_ARTIFACT]: "no plan file for this stage yet",
  [REASONS.PLAN_SYNC_OFF]: "plan-sync is not configured (PLAN_SYNC_REMOTE_URL empty)",
  [REASONS.NOT_PROVISIONED]: 'plan-sync is not provisioned — the user can run node "$AGENTS_CONFIG_DIR/bin/plan-sync-init"',
  [REASONS.NOT_PUBLISHED]: "the current content is not on the plan remote yet",
  [REASONS.NON_GITHUB]: "the plan remote is not GitHub, so there is no blob URL",
  [REASONS.INVALID_SESSION]: "the session id is not usable",
});

// linkFromSyncResult(result) -> {url} | {reason} — maps one syncPlanFile result.
function linkFromSyncResult(result) {
  const r = result && typeof result === "object" ? result : {};
  if (r.status === "pushed" && typeof r.url === "string" && r.url) return { url: r.url };
  if (r.status === "pushed") return { reason: REASONS.NON_GITHUB };
  if (r.status === "off") return { reason: REASONS.PLAN_SYNC_OFF };
  if (r.status === "not-provisioned") return { reason: REASONS.NOT_PROVISIONED };
  return { reason: REASONS.NOT_PUBLISHED };
}

function isRegularFile(p) {
  try { return fs.statSync(p).isFile(); } catch (_) { return false; }
}

// resolvePlanLink(sid, stage, {plansDir?, absPath?}) -> {url, kind: "blob"} | {reason}.
// Read-only and network-free: it judges the local tracking ref, never fetches or pushes.
function resolvePlanLink(sid, stage, opts) {
  if (typeof sid !== "string" || !SID_RE.test(sid)) return { reason: REASONS.INVALID_SESSION };
  try {
    const o = opts || {};
    const PS = require("./plan-sync");
    let plansDir = o.plansDir;
    if (!plansDir) plansDir = require("./workflow-plans-dir").getWorkflowPlansDir();
    if (!STAGES.includes(stage)) return { reason: REASONS.NO_ARTIFACT };
    const absPath = o.absPath || path.join(plansDir, `${sid}-${stage}.md`);
    if (!isRegularFile(absPath)) return { reason: REASONS.NO_ARTIFACT };
    const env = PS.resolveRemoteUrl();
    if (!env.value) return { reason: REASONS.PLAN_SYNC_OFF };
    const cp = PS.checkProvisioned(plansDir, env.value);
    if (!cp.ok) return { reason: REASONS.NOT_PROVISIONED };
    if (!PS.parseGitHubRemote(cp.pushUrl)) return { reason: REASONS.NON_GITHUB };
    const url = PS.publishedBlobUrl(plansDir, absPath);
    return url ? { url, kind: "blob" } : { reason: REASONS.NOT_PUBLISHED };
  } catch (_) {
    return { reason: REASONS.NOT_PUBLISHED };
  }
}

// entryLine(entry) — one line per stage; only stage, url and reason are ever read.
function entryLine(entry) {
  const e = entry || {};
  const stage = STAGES.includes(e.stage) ? e.stage : "plan";
  if (typeof e.url === "string" && /^https:\/\//.test(e.url)) return `- ${stage}: ${e.url}`;
  const reason = Object.values(REASONS).includes(e.reason) ? e.reason : REASONS.NOT_PUBLISHED;
  return `- ${stage}: unavailable (${reason}: ${REASON_TEXT[reason]})`;
}

// renderModelContext(entries, {when: "after-write" | "confirm"}) -> additionalContext text.
function renderModelContext(entries, opts) {
  const list = Array.isArray(entries) ? entries : [];
  const when = opts && opts.when === "confirm" ? "confirm" : "after-write";
  const hasUrl = list.some((e) => e && typeof e.url === "string" && e.url);
  const head = when === "confirm"
    ? "[plan-link] The plan being confirmed:"
    : "[plan-link] Plan artifact written:";
  const lines = [head, ...list.map(entryLine)];
  if (hasUrl && when === "confirm") {
    lines.push("The user reviews the plan through this URL: it must appear in your response body text (CPA-3), never inside the CONFIRM echo.");
  } else if (hasUrl) {
    lines.push("Write this URL in your response text so the user can open the plan.");
  }
  lines.push("Never show a local file path for a plan; when no URL exists, name the stage and say the plan is not published.");
  return lines.join("\n");
}

module.exports = { REASONS, STAGES, linkFromSyncResult, resolvePlanLink, renderModelContext };
