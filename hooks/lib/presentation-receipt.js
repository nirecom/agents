"use strict";
// hooks/lib/presentation-receipt.js — the presentation receipt (#2729): the Stop hook
// (stop-confirm-plan-guard.js) writes one per stage only for a turn it let through that closed on
// the stage's plan-link line; confirm-checkpoint.js passes a CONFIRM echo only when the receipt
// still matches today's path, link and content, and consumes it. The receipt, not the transcript
// shape, is what proves the user was shown the plan being approved.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { getSessionStateDir } = require("../workflow-state");
const { normalizeSlashes } = require("./path-match");
const { PLAN_STAGE_TABLE } = require("../workflow-state/plan-stage-table");
const { controlPath } = require("../workflow-state/state-io/control-dir");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const STAGES = Object.freeze(Object.values(PLAN_STAGE_TABLE).map((row) => row.suffix));
const validSid = (sid) => typeof sid === "string" && SID_RE.test(sid);

// approvalArtifactPath(sid, stage) -> <plans>/<first_session_id>-<stage>.md, the file the approval
// binds (#2748); null for an unusable sid or stage.
function approvalArtifactPath(sid, stage) {
  try {
    return require("../workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, stage).path;
  } catch (_) {
    return null;
  }
}

// linkKey(linkResult) -> the URL when one exists, else the local path, else null.
function linkKey(link) {
  if (!link || typeof link !== "object") return null;
  if (typeof link.url === "string" && link.url) return link.url;
  if (typeof link.path === "string" && link.path) return link.path;
  return null;
}

function samePath(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || !a || !b) return false;
  const norm = (p) => {
    const r = normalizeSlashes(path.resolve(p));
    return process.platform === "win32" ? r.toLowerCase() : r;
  };
  try { return norm(a) === norm(b); } catch (_) { return false; }
}

function receiptPath(sid, stage) {
  return path.join(getSessionStateDir(sid), `${sid}.confirm-plan-receipt-${stage}.json`);
}

const RECEIPT_LOG_NAME = "presentation-receipt-log.jsonl";

// appendReceiptLog(sid, event, stage): one {event, stage, path, at} line (#2804); never throws.
function appendReceiptLog(sid, event, stage) {
  try {
    const line = { event, stage, path: receiptPath(sid, stage), at: new Date().toISOString() };
    fs.appendFileSync(controlPath(sid, RECEIPT_LOG_NAME, { forWrite: true }), `${JSON.stringify(line)}\n`, "utf8");
  } catch (_) { /* the log is diagnostic only */ }
}

// readReceiptLog(sid) -> the parsed log lines, [] when absent or unreadable; never throws.
function readReceiptLog(sid) {
  try {
    const raw = fs.readFileSync(controlPath(sid, RECEIPT_LOG_NAME), "utf8");
    return raw.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch (_) { return null; } }).filter(Boolean);
  } catch (_) {
    return [];
  }
}

// A link stands for the plan only as an http(s) URL, or as the plan's own local path.
function validLink(link, absPath) {
  if (!link || typeof link !== "object" || typeof link.value !== "string" || !link.value) return false;
  if (link.kind === "url") return /^https?:\/\//.test(link.value);
  if (link.kind === "path") return samePath(link.value, absPath);
  return false;
}

// writeReceipt(sid, stage, {absPath, link, contentSha, anchorUuid}) -> true when written.
function writeReceipt(sid, stage, fields) {
  const f = fields || {};
  if (!validSid(sid) || !STAGES.includes(stage)) return false;
  if (typeof f.absPath !== "string" || !f.absPath || typeof f.contentSha !== "string" || !f.contentSha) return false;
  if (!validLink(f.link, f.absPath)) return false;
  const file = receiptPath(sid, stage);
  const tmp = `${file}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  const body = {
    absPath: f.absPath, link: { kind: f.link.kind, value: f.link.value }, contentSha: f.contentSha,
    anchorUuid: typeof f.anchorUuid === "string" ? f.anchorUuid : "", writtenAt: new Date().toISOString(),
  };
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(body), "utf8");
    fs.renameSync(tmp, file);
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* tmp never written */ }
    return false;
  }
  appendReceiptLog(sid, "write", stage);
  return true;
}

function wellFormed(r) {
  if (!r || typeof r !== "object" || Array.isArray(r)) return false;
  for (const k of ["absPath", "contentSha", "anchorUuid", "writtenAt"]) {
    if (typeof r[k] !== "string") return false;
  }
  return r.absPath !== "" && r.contentSha !== "" && validLink(r.link, r.absPath);
}

// readReceipt(sid, stage) -> {ok:true, receipt} | {ok:false, reason:"absent"|"unreadable"}.
function readReceipt(sid, stage) {
  if (!validSid(sid) || !STAGES.includes(stage)) return { ok: false, reason: "absent" };
  const file = receiptPath(sid, stage);
  if (!fs.existsSync(file)) return { ok: false, reason: "absent" };
  let receipt;
  try { receipt = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return { ok: false, reason: "unreadable" }; }
  return wellFormed(receipt) ? { ok: true, receipt } : { ok: false, reason: "unreadable" };
}

// discardReceipt(sid, stage): both the consumption on pass and the invalidation; never throws.
function discardReceipt(sid, stage) {
  if (!validSid(sid) || !STAGES.includes(stage)) return;
  try { fs.unlinkSync(receiptPath(sid, stage)); } catch (_) { /* absent: nothing to discard */ }
}

// consumeReceipt(sid, stage) -> true only for the one caller whose unlink removed the receipt, so two
// concurrent CONFIRM calls cannot both spend it.
function consumeReceipt(sid, stage) {
  if (!validSid(sid) || !STAGES.includes(stage)) return false;
  try { fs.unlinkSync(receiptPath(sid, stage)); } catch (_) { return false; }
  appendReceiptLog(sid, "consume", stage);
  return true;
}

// matchReceipt(receipt, {absPath, link, contentSha}) -> {ok:true} | {ok:false, cause}.
function matchReceipt(receipt, current) {
  const r = receipt || {};
  const c = current || {};
  if (!samePath(r.absPath, c.absPath)) return { ok: false, cause: "path" };
  const rl = r.link || {};
  const cl = c.link || {};
  if (rl.kind !== cl.kind || rl.value !== cl.value) return { ok: false, cause: "link" };
  if (typeof r.contentSha !== "string" || !r.contentSha || r.contentSha !== c.contentSha) return { ok: false, cause: "content" };
  return { ok: true };
}

module.exports = {
  STAGES, approvalArtifactPath, linkKey, samePath,
  receiptPath, writeReceipt, readReceipt, discardReceipt, consumeReceipt, matchReceipt, readReceiptLog,
};
