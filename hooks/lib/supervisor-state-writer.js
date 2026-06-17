"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { createEmptyState, validate, validateFinding, SEVERITY_VALUES, L2_PHASE_VALUES } = require("./supervisor-state-schema");

const LAYER2_PATCH_KEYS = new Set(["l2_armed_at", "last_run_at", "cumulative_severity", "findings", "l2_phase"]);

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

// Axis A (#885) — co-block back-annotation tuning.
// Scan only the most recent N findings, only when within W ms of the new
// finding's timestamp. Both bounds protect against cross-event correlation
// (idle session reuses, or unrelated bursts).
const CO_BLOCK_RECENCY = 5;
const CO_BLOCK_WINDOW_MS = 10000;

// Sibling-match key extraction (#885).
// Hooks self-report via reportBlock() with detail of shape
// `hook blocked: <reporter> on <command>`. To correlate a new block with a
// recent sibling block of the SAME command but DIFFERENT reporter, strip the
// "hook blocked: <reporter> on " prefix so the residual is just the command.
// Falls back to the full detail when the prefix is absent (non-block finding).
function extractCoBlockKey(detail) {
  if (typeof detail !== "string") return null;
  const m = detail.match(/^hook blocked: [^ ]+ on (.*)$/);
  return m ? m[1] : detail;
}

function unionStableDedup(existing, additions) {
  const seen = new Set();
  const out = [];
  if (Array.isArray(existing)) {
    for (const r of existing) {
      if (typeof r === "string" && !seen.has(r)) { seen.add(r); out.push(r); }
    }
  }
  for (const r of additions) {
    if (typeof r === "string" && !seen.has(r)) { seen.add(r); out.push(r); }
  }
  return out;
}

function getStatePath(sessionId) {
  if (!SESSION_ID_RE.test(sessionId)) throw new Error(`invalid sessionId: ${sessionId}`);
  return path.join(getWorkflowPlansDir(), `${sessionId}-supervisor-state.json`);
}

function readStateOrInit(sessionId) {
  const filePath = getStatePath(sessionId);
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    return JSON.parse(raw);
  } catch (_) {
    return createEmptyState(sessionId);
  }
}

function writeAtomic(filePath, state) {
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function ensureLayer2Scheduled(state, sessionId) {
  if (!state.layer2 || typeof state.layer2 !== "object" || Array.isArray(state.layer2)) return;
  const phase = state.layer2.l2_phase;
  if (phase === "done" || phase === "frozen") return;
  if (sessionId && SESSION_ID_RE.test(sessionId)) {
    try {
      if (fs.existsSync(path.join(getWorkflowPlansDir(), `${sessionId}-final-report-env.json`))) return;
    } catch (_) {}
  }
  if (state.layer2.l2_armed_at == null) {
    state.layer2.l2_armed_at = new Date().toISOString();
    if (phase == null) state.layer2.l2_phase = "pending";
  }
}

function validateL2PhaseTransition(currentPhase, nextPhase) {
  if (currentPhase === nextPhase) return { ok: true, errors: [] };
  if (currentPhase === "frozen") return { ok: false, errors: ["cannot transition from frozen (terminal state)"] };
  if (currentPhase === "done" && nextPhase === "pending") return { ok: false, errors: ["cannot re-schedule L2 after done"] };
  if (currentPhase === "done" && nextPhase === null) return { ok: false, errors: ["cannot revert done to null"] };
  return { ok: true, errors: [] };
}

function appendFinding(sessionId, finding) {
  const vr = validateFinding(finding);
  if (!vr.ok) return false;

  const plansDir = getWorkflowPlansDir();
  fs.mkdirSync(plansDir, { recursive: true });
  const filePath = getStatePath(sessionId);

  const state = readStateOrInit(sessionId);

  const now = Date.now();
  const nowIso = new Date(now).toISOString();

  const findings = state.layer1.findings;
  if (findings.length > 0) {
    const last = findings[findings.length - 1];
    const catsKey = (f) => [...(f.categories || [])].sort().join(",");
    // Axis A (#885): extend de-dupe key with reason and context.git_root_resolved.
    // context.cwd and co_blocked_by are intentionally excluded — same logical
    // event must collapse even with different working directories, and
    // co_blocked_by is back-annotated after the dedupe check.
    const lastCtxResolved = last.context ? last.context.git_root_resolved : undefined;
    const newCtxResolved = finding.context ? finding.context.git_root_resolved : undefined;
    if (
      catsKey(last) === catsKey(finding) &&
      last.severity === finding.severity &&
      last.detail === finding.detail &&
      last.reporter === finding.reporter &&
      last.reason === finding.reason &&
      lastCtxResolved === newCtxResolved
    ) {
      const prevArmedAt = state.layer2 && state.layer2.l2_armed_at;
      ensureLayer2Scheduled(state, sessionId);
      if (state.layer2 && state.layer2.l2_armed_at !== prevArmedAt) {
        const vr3 = validate(state);
        if (vr3.ok) writeAtomic(filePath, state);
      }
      return true;
    }
  }

  // Axis A (#885): co-block sibling search (append path only, not collapse).
  // Walk the last N findings most-recent-first; match a sibling whose
  // command (extracted from `hook blocked: <r> on <cmd>` detail) equals the
  // new finding's command AND whose reporter differs from the new finding's.
  // CWD is intentionally NOT part of the match — enforce-issue-close emits
  // 3-arg with no context.cwd while enforce-worktree emits 4-arg with cwd;
  // requiring CWD parity would break the canonical double-block scenario.
  let siblingIdx = -1;
  if (typeof finding.reporter === "string") {
    const newKey = extractCoBlockKey(finding.detail);
    if (newKey !== null) {
      const start = Math.max(0, findings.length - CO_BLOCK_RECENCY);
      for (let i = findings.length - 1; i >= start; i--) {
        const cand = findings[i];
        if (!cand || cand.reporter === finding.reporter) continue;
        if (typeof cand.timestamp !== "string") continue;
        const candTs = Date.parse(cand.timestamp);
        if (!Number.isFinite(candTs)) continue;
        if (Math.abs(now - candTs) > CO_BLOCK_WINDOW_MS) continue;
        const candKey = extractCoBlockKey(cand.detail);
        if (candKey === null || candKey !== newKey) continue;
        siblingIdx = i;
        break;
      }
    }
  }

  let newFinding = { ...finding, timestamp: nowIso };
  if (siblingIdx >= 0) {
    const sibling = findings[siblingIdx];
    // Idempotent bidirectional populate: dedup elements, skip if already present.
    const newCo = unionStableDedup(newFinding.co_blocked_by, [sibling.reporter]);
    if (newCo.length > 0) newFinding.co_blocked_by = newCo;
    const sibCo = unionStableDedup(sibling.co_blocked_by, [finding.reporter]);
    if (sibCo.length > 0) {
      // In-place mutation: write back the same object in the findings array.
      sibling.co_blocked_by = sibCo;
    }
  }

  findings.push(newFinding);
  state.last_updated = nowIso;

  ensureLayer2Scheduled(state, sessionId);

  const vr2 = validate(state);
  if (!vr2.ok) {
    console.error(`[supervisor-state-writer] validate failed: ${vr2.errors.join("; ")}`);
    return false;
  }

  writeAtomic(filePath, state);
  return true;
}

function readState(sessionId) {
  try {
    const raw = fs.readFileSync(getStatePath(sessionId), "utf8");
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

function writeLayer2State(sessionId, patch) {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return false;

  // Reject unknown keys
  for (const k of Object.keys(patch)) {
    if (!LAYER2_PATCH_KEYS.has(k)) return false;
  }

  // Validate scalar override types
  if ("l2_armed_at" in patch && patch.l2_armed_at !== null && typeof patch.l2_armed_at !== "string") return false;
  if ("last_run_at" in patch && patch.last_run_at !== null && typeof patch.last_run_at !== "string") return false;
  if ("cumulative_severity" in patch && patch.cumulative_severity !== null && !SEVERITY_VALUES.includes(patch.cumulative_severity)) return false;
  if ("l2_phase" in patch && !L2_PHASE_VALUES.includes(patch.l2_phase)) return false;

  // Validate findings
  if ("findings" in patch) {
    if (!Array.isArray(patch.findings)) return false;
    for (const f of patch.findings) {
      const vr = validateFinding(f);
      if (!vr.ok) return false;
    }
  }

  const plansDir = getWorkflowPlansDir();
  fs.mkdirSync(plansDir, { recursive: true });
  const filePath = getStatePath(sessionId);

  const state = readStateOrInit(sessionId);

  // Up-cast S-1-era layer2 to S-2 shape
  const existing = state.layer2 && typeof state.layer2 === "object" && !Array.isArray(state.layer2) ? state.layer2 : {};
  const currentPhase = (existing.l2_phase === undefined) ? null : existing.l2_phase;
  if ("l2_phase" in patch) {
    const vr = validateL2PhaseTransition(currentPhase, patch.l2_phase);
    if (!vr.ok) {
      console.error("[supervisor-state-writer] invalid l2_phase transition: " + vr.errors.join("; "));
      return false;
    }
  }
  const effectivePhase = ("l2_phase" in patch) ? patch.l2_phase : currentPhase;
  if ((effectivePhase === "done" || effectivePhase === "frozen") && "l2_armed_at" in patch && patch.l2_armed_at !== null) {
    console.error("[supervisor-state-writer] cannot set l2_armed_at while l2_phase=" + effectivePhase);
    return false;
  }
  const layer2 = {
    l2_armed_at: null,
    last_run_at: null,
    cumulative_severity: null,
    findings: [],
    l2_phase: null,
    ...existing,
  };

  // Apply scalar overrides (explicit-clear via null permitted)
  if ("l2_armed_at" in patch) layer2.l2_armed_at = patch.l2_armed_at;
  if ("last_run_at" in patch) layer2.last_run_at = patch.last_run_at;
  if ("cumulative_severity" in patch) layer2.cumulative_severity = patch.cumulative_severity;
  if ("l2_phase" in patch) layer2.l2_phase = patch.l2_phase;

  // Append findings
  if ("findings" in patch) {
    const ts = new Date().toISOString();
    for (const f of patch.findings) {
      layer2.findings.push({ ...f, timestamp: ts });
    }
  }

  state.layer2 = layer2;
  state.last_updated = new Date().toISOString();

  const vr2 = validate(state);
  if (!vr2.ok) {
    console.error(`[supervisor-state-writer] writeLayer2State validate failed: ${vr2.errors.join("; ")}`);
    return false;
  }

  writeAtomic(filePath, state);
  return true;
}

module.exports = { getStatePath, readStateOrInit, ensureLayer2Scheduled, appendFinding, readState, writeLayer2State };
