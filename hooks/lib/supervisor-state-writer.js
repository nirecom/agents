"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { createEmptyState, validate, validateFinding, SEVERITY_VALUES, L2_PHASE_VALUES } = require("./supervisor-state-schema");

const LAYER2_PATCH_KEYS = new Set(["next_check_at", "last_run_at", "cumulative_severity", "findings", "l2_phase"]);

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

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

function ensureLayer2Scheduled(state) {
  if (!state.layer2 || typeof state.layer2 !== "object" || Array.isArray(state.layer2)) return;
  const phase = state.layer2.l2_phase;
  if (phase === "done" || phase === "frozen") return;
  if (state.layer2.next_check_at == null) {
    state.layer2.next_check_at = new Date().toISOString();
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

  const findings = state.layer1.findings;
  if (findings.length > 0) {
    const last = findings[findings.length - 1];
    const catsKey = (f) => [...(f.categories || [])].sort().join(",");
    if (
      catsKey(last) === catsKey(finding) &&
      last.severity === finding.severity &&
      last.detail === finding.detail &&
      last.reporter === finding.reporter
    ) {
      const prevNextCheck = state.layer2 && state.layer2.next_check_at;
      ensureLayer2Scheduled(state);
      if (state.layer2 && state.layer2.next_check_at !== prevNextCheck) {
        const vr3 = validate(state);
        if (vr3.ok) writeAtomic(filePath, state);
      }
      return true;
    }
  }

  findings.push({ ...finding, timestamp: new Date().toISOString() });
  state.last_updated = new Date().toISOString();

  ensureLayer2Scheduled(state);

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
  if ("next_check_at" in patch && patch.next_check_at !== null && typeof patch.next_check_at !== "string") return false;
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
  if ((effectivePhase === "done" || effectivePhase === "frozen") && "next_check_at" in patch && patch.next_check_at !== null) {
    console.error("[supervisor-state-writer] cannot set next_check_at while l2_phase=" + effectivePhase);
    return false;
  }
  const layer2 = {
    next_check_at: null,
    last_run_at: null,
    cumulative_severity: null,
    findings: [],
    l2_phase: null,
    ...existing,
  };

  // Apply scalar overrides (explicit-clear via null permitted)
  if ("next_check_at" in patch) layer2.next_check_at = patch.next_check_at;
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
