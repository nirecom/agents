"use strict";
// hooks/lib/presentation-receipt.js — the presentation receipt (#2729): the Stop hook
// (stop-confirm-plan-guard.js) writes one per plan step only for a turn it let through that closed
// on the step's plan-link line; confirm-checkpoint.js passes a CONFIRM echo only when the receipt
// still matches today's path, link and content, and consumes it. The receipt, not the transcript
// shape, is what proves the user was shown the plan being approved.
// Receipts are keyed by the workflow step (#2820); approvalArtifactPath alone takes the plan
// artifact name. A caller holding an artifact name converts it with stepForSuffix first.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { getSessionStateDir } = require("../workflow-state");
const { normalizeSlashes } = require("./path-match");
const { PLAN_STEP_TABLE } = require("../workflow-state/plan-step-table");
const { controlPath } = require("../workflow-state/state-io/control-dir");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const RECEIPT_STEPS = Object.freeze(Object.keys(PLAN_STEP_TABLE));
const validSid = (sid) => typeof sid === "string" && SID_RE.test(sid);
const validKey = (sid, step) => validSid(sid) && RECEIPT_STEPS.includes(step);

// approvalArtifactPath(sid, artifact) -> <plans>/<first_session_id>-<artifact>.md, the file the
// approval binds (#2748); null for an unusable sid or plan artifact name.
function approvalArtifactPath(sid, artifact) {
  try {
    return require("../workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, artifact).path;
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

function receiptPath(sid, step) {
  return path.join(getSessionStateDir(sid), `${sid}.confirm-plan-receipt-${step}.json`);
}

// --- BEGIN temporary: workflow stage -> workflow step migration added 2026-11-02 ---
// deletion-condition: remove once 30 days (the control dir lifetime) have passed since merge and no --stage caller remains in this repo or the global instructions
// A receipt or log line written before #2820 is keyed by the plan artifact name; only
// clarify_intent (old "intent") is spelled differently.
const STAGE_TO_STEP = () => require("./temporary-migrations/stage-to-step");

// legacyReceiptFile(sid, step) -> the pre-#2820 receipt path when it differs from receiptPath, else null.
function legacyReceiptFile(sid, step) {
  try {
    const p = STAGE_TO_STEP().legacyReceiptPath(sid, step);
    return typeof p === "string" && p && p !== receiptPath(sid, step) ? p : null;
  } catch (_) {
    return null;
  }
}

// receiptFileToRead(sid, step) -> the step-named receipt when present (it wins over a legacy one),
// else the legacy one when present, else null.
function receiptFileToRead(sid, step) {
  const file = receiptPath(sid, step);
  if (fs.existsSync(file)) return file;
  const legacy = legacyReceiptFile(sid, step);
  return legacy && fs.existsSync(legacy) ? legacy : null;
}

// unlinkLegacyReceipt(sid, step) -> true when a legacy receipt was removed; never throws.
function unlinkLegacyReceipt(sid, step) {
  const legacy = legacyReceiptFile(sid, step);
  if (!legacy) return false;
  try { fs.unlinkSync(legacy); return true; } catch (_) { return false; }
}

function normalizeLogLine(l) {
  try { return STAGE_TO_STEP().normalizeReceiptLogLine(l); } catch (_) { return l; }
}
// --- END temporary: workflow stage -> workflow step migration ---

const RECEIPT_LOG_NAME = "presentation-receipt-log.jsonl";

// appendReceiptLog(sid, event, step): one {event, step, path, at} line (#2804); never throws.
function appendReceiptLog(sid, event, step) {
  try {
    const line = { event, step, path: receiptPath(sid, step), at: new Date().toISOString() };
    fs.appendFileSync(controlPath(sid, RECEIPT_LOG_NAME, { forWrite: true }), `${JSON.stringify(line)}\n`, "utf8");
  } catch (_) { /* the log is diagnostic only */ }
}

// readReceiptLog(sid) -> the parsed log lines keyed by step, [] when absent or unreadable; never throws.
function readReceiptLog(sid) {
  try {
    const raw = fs.readFileSync(controlPath(sid, RECEIPT_LOG_NAME), "utf8");
    return raw.split("\n").filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (_) { return null; } })
      .filter(Boolean).map(normalizeLogLine);
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

// writeBody(file, body, verify) -> true when renamed into place; verify() runs just before the rename.
function writeBody(file, body, verify) {
  const tmp = `${file}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(body), "utf8");
    if (verify && !verify()) {
      fs.unlinkSync(tmp);
      return false;
    }
    fs.renameSync(tmp, file);
    return true;
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* tmp never written */ }
    return false;
  }
}

const isContinued = (receipt) => !!receipt && typeof receipt.continuedAt === "string" && receipt.continuedAt !== "";

// writeReceipt(sid, step, {absPath, link, contentSha, anchorUuid, carryMark}) -> true when written.
// carryMark keeps the existing continuedAt only while the receipt's path, link and content are unchanged.
function writeReceipt(sid, step, fields) {
  const f = fields || {};
  if (!validKey(sid, step)) return false;
  if (typeof f.absPath !== "string" || !f.absPath || typeof f.contentSha !== "string" || !f.contentSha) return false;
  if (!validLink(f.link, f.absPath)) return false;
  const body = {
    absPath: f.absPath, link: { kind: f.link.kind, value: f.link.value }, contentSha: f.contentSha,
    anchorUuid: typeof f.anchorUuid === "string" ? f.anchorUuid : "", writtenAt: new Date().toISOString(),
  };
  if (f.carryMark === true) {
    const prev = readReceipt(sid, step);
    if (prev.ok && isContinued(prev.receipt) && matchReceipt(prev.receipt, body).ok) body.continuedAt = prev.receipt.continuedAt;
  }
  if (!writeBody(receiptPath(sid, step), body)) return false;
  // --- BEGIN temporary: workflow stage -> workflow step migration added 2026-11-02 ---
  // deletion-condition: remove with the legacy receipt name block above once 30 days have passed since merge
  unlinkLegacyReceipt(sid, step); // the two names never coexist, so one receipt is spent once
  // --- END temporary: workflow stage -> workflow step migration ---
  appendReceiptLog(sid, "write", step);
  return true;
}

const sameReceipt = (a, b) => matchReceipt(a, b).ok && a.anchorUuid === b.anchorUuid;

// markContinued(sid, step) -> true when the receipt now carries continuedAt; false when it is absent,
// unreadable, consumed or replaced before the rename, or the write fails. Never throws.
function markContinued(sid, step) {
  try {
    const before = readReceipt(sid, step);
    if (!before.ok) return false;
    const body = Object.assign({}, before.receipt, { continuedAt: new Date().toISOString() });
    const verify = () => {
      const now = readReceipt(sid, step);
      return now.ok && sameReceipt(now.receipt, before.receipt);
    };
    const written = writeBody(receiptPath(sid, step), body, verify);
    // --- BEGIN temporary: workflow stage -> workflow step migration added 2026-11-02 ---
    // deletion-condition: remove with the legacy receipt name block above once 30 days have passed since merge
    if (written) unlinkLegacyReceipt(sid, step);
    // --- END temporary: workflow stage -> workflow step migration ---
    return written;
  } catch (_) {
    return false;
  }
}

function wellFormed(r) {
  if (!r || typeof r !== "object" || Array.isArray(r)) return false;
  for (const k of ["absPath", "contentSha", "anchorUuid", "writtenAt"]) {
    if (typeof r[k] !== "string") return false;
  }
  return r.absPath !== "" && r.contentSha !== "" && validLink(r.link, r.absPath);
}

// readReceipt(sid, step) -> {ok:true, receipt} | {ok:false, reason:"absent"|"unreadable"}.
function readReceipt(sid, step) {
  if (!validKey(sid, step)) return { ok: false, reason: "absent" };
  const file = receiptFileToRead(sid, step);
  if (!file) return { ok: false, reason: "absent" };
  let receipt;
  try { receipt = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return { ok: false, reason: "unreadable" }; }
  return wellFormed(receipt) ? { ok: true, receipt } : { ok: false, reason: "unreadable" };
}

// discardReceipt(sid, step): both the consumption on pass and the invalidation; never throws.
function discardReceipt(sid, step) {
  if (!validKey(sid, step)) return;
  try { fs.unlinkSync(receiptPath(sid, step)); } catch (_) { /* absent: nothing to discard */ }
  unlinkLegacyReceipt(sid, step);
}

// consumeReceipt(sid, step) -> true only for the one caller whose unlink removed the receipt, so two
// concurrent CONFIRM calls cannot both spend it. No receipt of the step outlives the consume.
function consumeReceipt(sid, step) {
  if (!validKey(sid, step)) return false;
  let removed = false;
  try { fs.unlinkSync(receiptPath(sid, step)); removed = true; } catch (_) { /* absent: try the legacy name */ }
  // --- BEGIN temporary: workflow stage -> workflow step migration added 2026-11-02 ---
  // deletion-condition: remove with the legacy receipt name block above once 30 days have passed since merge
  // The legacy receipt is a cleanup, not a second spend: only the file readReceipt would read counts.
  const legacyRemoved = unlinkLegacyReceipt(sid, step);
  if (!removed && legacyRemoved) removed = true;
  // --- END temporary: workflow stage -> workflow step migration ---
  if (!removed) return false;
  appendReceiptLog(sid, "consume", step);
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
  RECEIPT_STEPS, approvalArtifactPath, linkKey, samePath,
  receiptPath, writeReceipt, readReceipt, discardReceipt, consumeReceipt, matchReceipt, readReceiptLog,
  isContinued, markContinued,
};
