"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { createEmptyState, validate, validateFinding, SEVERITY_VALUES, ALERT_PHASE_VALUES, ALERT_ELIGIBLE_PHASE_VALUES, ALERT_RETRY_THRESHOLD, AUDIT_PHASE_VALUES, AUDIT_VERDICT_VALUES, AUDIT_RETRY_THRESHOLD } = require("./supervisor-state-schema");
const { resolveWorkflowSessionId } = require("./resolve-workflow-session-id");
const findingStatus = require("./supervisor-finding-status");

const ALERT_PATCH_KEYS = new Set(["alert_armed_at", "last_run_at", "cumulative_severity", "findings", "alert_phase", "alert_cause", "alert_retry_count", "findings_surfaced_at", "alert_eligible_phase"]);

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

// Migrate pre-#1092 layer2/layer3 schema to alert/audit in-place.
// Called by readStateOrInit; safe to call on already-migrated states.
function migrateLegacyState(state) {
  if (state.layer2 && typeof state.layer2 === "object" && !Array.isArray(state.layer2) &&
      (typeof state.alert !== "object" || state.alert === null || Array.isArray(state.alert))) {
    const l2 = state.layer2;
    state.alert = {
      alert_armed_at: l2.l2_armed_at !== undefined ? l2.l2_armed_at : null,
      last_run_at: l2.last_run_at !== undefined ? l2.last_run_at : null,
      cumulative_severity: l2.cumulative_severity !== undefined ? l2.cumulative_severity : null,
      findings: Array.isArray(l2.findings) ? l2.findings : [],
      alert_phase: l2.l2_phase !== undefined ? l2.l2_phase : null,
      alert_cause: l2.l2_cause !== undefined ? l2.l2_cause : null,
      alert_retry_count: typeof l2.l2_retry_count === "number" ? l2.l2_retry_count : 0,
      findings_surfaced_at: l2.findings_surfaced_at !== undefined ? l2.findings_surfaced_at : null,
      alert_eligible_phase: l2.l2_eligible_phase !== undefined ? l2.l2_eligible_phase : null,
    };
    delete state.layer2;
  }
  if (state.layer3 && typeof state.layer3 === "object" && !Array.isArray(state.layer3) &&
      (typeof state.audit !== "object" || state.audit === null || Array.isArray(state.audit))) {
    const l3 = state.layer3;
    state.audit = {
      audit_phase: l3.l3_phase !== undefined ? l3.l3_phase : null,
      audit_verdict: l3.l3_verdict !== undefined ? l3.l3_verdict : null,
      audit_last_run_at: l3.l3_last_run_at !== undefined ? l3.l3_last_run_at : null,
      audit_armed_at: l3.l3_armed_at !== undefined ? l3.l3_armed_at : null,
      audit_cause: l3.l3_cause !== undefined ? l3.l3_cause : null,
      audit_retry_count: typeof l3.l3_retry_count === "number" ? l3.l3_retry_count : 0,
      findings: Array.isArray(l3.findings) ? l3.findings : [],
    };
    delete state.layer3;
  }
  // Backfill top-level timestamps required by validate() that pre-#1092 states lack.
  const now = new Date().toISOString();
  if (!state.created_at) state.created_at = now;
  if (!state.last_updated) state.last_updated = now;
  return state;
}

function readStateOrInit(sessionId) {
  const filePath = getStatePath(sessionId);
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    return migrateLegacyState(JSON.parse(raw));
  } catch (_) {
    return createEmptyState(sessionId);
  }
}

function writeAtomic(filePath, state) {
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function ensureAlertScheduled(state, sessionId, finding = null) {
  // Arming threshold: notice-severity findings do not arm alert mode.
  if (finding !== null && finding !== undefined && finding.severity === "notice") return;

  if (!state.alert || typeof state.alert !== "object" || Array.isArray(state.alert)) return;
  const phase = state.alert.alert_phase;
  if (phase === "done") return;

  if (phase !== "frozen") {
    const plansDir = getWorkflowPlansDir();
    const candidates = new Set();
    if (sessionId && SESSION_ID_RE.test(sessionId)) candidates.add(sessionId);
    try {
      const wsid = resolveWorkflowSessionId();
      if (wsid && SESSION_ID_RE.test(wsid)) candidates.add(wsid);
    } catch (_) {}

    for (const sid of candidates) {
      try {
        if (fs.existsSync(path.join(plansDir, `${sid}-final-report-env.json`))) {
          // Anchor present: skip normal-run arm UNLESS late-phase eligibility is set (#997)
          if (state.alert.alert_eligible_phase !== "post_final_report_window") return;
        }
      } catch (_) {}
    }
  }

  if (state.alert.alert_armed_at == null) {
    state.alert.alert_armed_at = new Date().toISOString();
    if (phase == null) state.alert.alert_phase = "pending";
    if (phase === "frozen") {
      state.alert.alert_phase = "pending";
      state.alert.alert_retry_count = 0;
    }
  }
}

function validateAlertPhaseTransition(currentPhase, nextPhase) {
  if (currentPhase === nextPhase) return { ok: true, errors: [] };
  if (currentPhase === "frozen" && nextPhase !== "pending") return { ok: false, errors: ["cannot transition from frozen: only frozen→pending (re-arm) is allowed"] };
  if (currentPhase === "done" && nextPhase === "pending") return { ok: false, errors: ["cannot re-schedule alert after done"] };
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
      const prevArmedAt = state.alert && state.alert.alert_armed_at;
      ensureAlertScheduled(state, sessionId, finding);
      if (state.alert && state.alert.alert_armed_at !== prevArmedAt) {
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

  ensureAlertScheduled(state, sessionId, finding);

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

function writeAlertState(sessionId, patch) {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return false;

  // Reject unknown keys
  for (const k of Object.keys(patch)) {
    if (!ALERT_PATCH_KEYS.has(k)) return false;
  }

  // Validate scalar override types
  if ("alert_armed_at" in patch && patch.alert_armed_at !== null && typeof patch.alert_armed_at !== "string") return false;
  if ("last_run_at" in patch && patch.last_run_at !== null && typeof patch.last_run_at !== "string") return false;
  if ("cumulative_severity" in patch && patch.cumulative_severity !== null && !SEVERITY_VALUES.includes(patch.cumulative_severity)) return false;
  if ("alert_phase" in patch && !ALERT_PHASE_VALUES.includes(patch.alert_phase)) return false;
  if ("alert_cause" in patch && patch.alert_cause !== null && typeof patch.alert_cause !== "string") return false;
  if ("findings_surfaced_at" in patch && patch.findings_surfaced_at !== null && typeof patch.findings_surfaced_at !== "string") return false;
  if ("alert_eligible_phase" in patch && !ALERT_ELIGIBLE_PHASE_VALUES.includes(patch.alert_eligible_phase)) return false;

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

  // Up-cast S-1-era alert to S-2 shape
  const existing = state.alert && typeof state.alert === "object" && !Array.isArray(state.alert) ? state.alert : {};
  const currentPhase = (existing.alert_phase === undefined) ? null : existing.alert_phase;
  if ("alert_phase" in patch) {
    const vr = validateAlertPhaseTransition(currentPhase, patch.alert_phase);
    if (!vr.ok) {
      console.error("[supervisor-state-writer] invalid alert_phase transition: " + vr.errors.join("; "));
      return false;
    }
  }
  const effectivePhase = ("alert_phase" in patch) ? patch.alert_phase : currentPhase;
  if ((effectivePhase === "done" || effectivePhase === "frozen") && "alert_armed_at" in patch && patch.alert_armed_at !== null) {
    console.error("[supervisor-state-writer] cannot set alert_armed_at while alert_phase=" + effectivePhase);
    return false;
  }
  const alert = {
    alert_armed_at: null,
    last_run_at: null,
    cumulative_severity: null,
    findings: [],
    alert_phase: null,
    alert_cause: null,
    alert_retry_count: 0,
    findings_surfaced_at: null,
    alert_eligible_phase: null,
    ...existing,
  };

  // Apply scalar overrides (explicit-clear via null permitted)
  if ("alert_armed_at" in patch) alert.alert_armed_at = patch.alert_armed_at;
  if ("last_run_at" in patch) alert.last_run_at = patch.last_run_at;
  if ("cumulative_severity" in patch) alert.cumulative_severity = patch.cumulative_severity;
  if ("alert_phase" in patch) alert.alert_phase = patch.alert_phase;
  if ("alert_cause" in patch) alert.alert_cause = patch.alert_cause;

  // Co-clear alert_cause when alert_armed_at is cleared to prevent stale-cause mislabeling
  if ("alert_armed_at" in patch && patch.alert_armed_at === null && !("alert_cause" in patch)) {
    alert.alert_cause = null;
  }
  if ("alert_retry_count" in patch) alert.alert_retry_count = patch.alert_retry_count;
  if ("findings_surfaced_at" in patch) alert.findings_surfaced_at = patch.findings_surfaced_at;
  if ("alert_eligible_phase" in patch) alert.alert_eligible_phase = patch.alert_eligible_phase;

  // #905: terminal states must never carry a stale alert_armed_at.
  if (effectivePhase === "done" || effectivePhase === "frozen") {
    alert.alert_armed_at = null;
    alert.alert_cause = null;
  }

  // #912 C-HIGH-3: supervisor success path resets retry counter at writer SSOT.
  // Applies to ANY writeAlertState caller setting alert_phase=done (not just CLI),
  // so direct callers cannot leave a stale alert_retry_count carrying into the next cycle.
  // Explicit alert_retry_count in patch wins (test fixtures may set non-zero values).
  if (effectivePhase === "done" && !("alert_retry_count" in patch)) {
    alert.alert_retry_count = 0;
  }

  // Append findings. Draft-status entries get auto-assigned idx for later --confirm/--drop.
  if ("findings" in patch) {
    const ts = new Date().toISOString();
    for (const f of patch.findings) {
      const entry = { ...f, timestamp: ts };
      if (entry.status === "draft" && entry.idx === undefined) entry.idx = alert.findings.length;
      alert.findings.push(entry);
    }
  }

  state.alert = alert;
  state.last_updated = new Date().toISOString();

  const vr2 = validate(state);
  if (!vr2.ok) {
    console.error(`[supervisor-state-writer] writeAlertState validate failed: ${vr2.errors.join("; ")}`);
    return false;
  }

  writeAtomic(filePath, state);
  return true;
}

function incrementAlertRetryCount(sessionId) {
  const state = readStateOrInit(sessionId);
  const al = state.alert || {};
  // #912 C-HIGH-2: both done and frozen are terminal — never increment from either.
  // Without the done short-circuit, a stale retry_count on a done session could be
  // incremented into frozen via a later C3 / cumSev=error path, corrupting terminal-state semantics.
  if (al.alert_phase === "frozen" || al.alert_phase === "done") {
    return { count: al.alert_retry_count || 0, frozen: al.alert_phase === "frozen" };
  }
  const nextCount = (al.alert_retry_count || 0) + 1;
  if (nextCount >= ALERT_RETRY_THRESHOLD) {
    writeAlertState(sessionId, { alert_retry_count: nextCount, alert_phase: "frozen" });
    return { count: nextCount, frozen: true };
  }
  writeAlertState(sessionId, { alert_retry_count: nextCount });
  return { count: nextCount, frozen: false };
}

// #720: Audit writer. Symmetric to writeAlertState — accepts a small patch
// object, validates each field's type/enum, then merges into state.audit.
const AUDIT_PATCH_KEYS = new Set(["audit_phase", "audit_verdict", "audit_last_run_at", "audit_armed_at", "audit_cause", "audit_retry_count", "findings"]);

function writeAuditState(sessionId, patch) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return false;

  for (const k of Object.keys(patch)) {
    if (!AUDIT_PATCH_KEYS.has(k)) return false;
  }

  if ("audit_phase" in patch && !AUDIT_PHASE_VALUES.includes(patch.audit_phase)) return false;
  if ("audit_verdict" in patch && patch.audit_verdict !== null && !AUDIT_VERDICT_VALUES.includes(patch.audit_verdict)) return false;
  if ("audit_last_run_at" in patch && patch.audit_last_run_at !== null && typeof patch.audit_last_run_at !== "string") return false;
  if ("audit_armed_at" in patch && patch.audit_armed_at !== null && typeof patch.audit_armed_at !== "string") return false;
  if ("audit_cause" in patch && patch.audit_cause !== null && typeof patch.audit_cause !== "string") return false;
  if ("audit_retry_count" in patch && (!Number.isInteger(patch.audit_retry_count) || patch.audit_retry_count < 0)) return false;
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
  if (!state.audit || typeof state.audit !== "object" || Array.isArray(state.audit)) {
    state.audit = {};
  }

  for (const [k, v] of Object.entries(patch)) {
    if (k === "findings") {
      if (!Array.isArray(state.audit.findings)) state.audit.findings = [];
      const ts = new Date().toISOString();
      for (const f of v) state.audit.findings.push({ ...f, timestamp: ts });
    } else {
      state.audit[k] = v;
    }
  }
  // #912 mirror C-HIGH-3 to audit: setting phase=done resets retry counter at SSOT.
  if (patch.audit_phase === "done" && !("audit_retry_count" in patch)) {
    state.audit.audit_retry_count = 0;
  }
  state.last_updated = new Date().toISOString();

  const vr = validate(state);
  if (!vr.ok) {
    console.error(`[supervisor-state-writer] writeAuditState validate failed: ${vr.errors.join("; ")}`);
    return false;
  }
  writeAtomic(filePath, state);
  return true;
}

function incrementAuditRetryCount(sessionId) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return { count: 0, frozen: false };
  const state = readStateOrInit(sessionId);
  if (!state.audit || typeof state.audit !== "object" || Array.isArray(state.audit)) {
    state.audit = {};
  }
  const au = state.audit;
  // Terminal-state short-circuit (symmetric to alert increment).
  if (au.audit_phase === "frozen" || au.audit_phase === "done") {
    return { count: au.audit_retry_count || 0, frozen: au.audit_phase === "frozen" };
  }
  const nextCount = (au.audit_retry_count || 0) + 1;
  const patch = { audit_retry_count: nextCount };
  if (nextCount >= AUDIT_RETRY_THRESHOLD) patch.audit_phase = "frozen";
  writeAuditState(sessionId, patch);
  return { count: nextCount, frozen: nextCount >= AUDIT_RETRY_THRESHOLD };
}

function mutateAlertState(sid, mutator) {
  const fp = getStatePath(sid); const state = readStateOrInit(sid); mutator(state);
  state.last_updated = new Date().toISOString();
  const vr = validate(state);
  if (!vr.ok) { console.error(`[supervisor-state-writer] mutate failed: ${vr.errors.join("; ")}`); return false; }
  writeAtomic(fp, state); return true;
}
const confirmFinding = (sid, idx) => mutateAlertState(sid, (s) => findingStatus.confirmFinding(s, idx));
const dropFindings = (sid, idxs) => mutateAlertState(sid, (s) => findingStatus.dropFindings(s, idxs));
const promotePendingDraftsToConfirmed = (sid) => mutateAlertState(sid, (s) => findingStatus.promotePendingDraftsToConfirmed(s));

module.exports = { getStatePath, readStateOrInit, ensureAlertScheduled, appendFinding, readState, writeAlertState, writeAtomic, incrementAlertRetryCount, confirmFinding, dropFindings, promotePendingDraftsToConfirmed, validateAlertPhaseTransition, writeAuditState, incrementAuditRetryCount };
