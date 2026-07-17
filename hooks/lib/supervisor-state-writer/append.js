"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { validateFinding, validate } = require("../supervisor-state-schema");
const {
  SESSION_ID_RE,
  CO_BLOCK_RECENCY,
  CO_BLOCK_WINDOW_MS,
  extractCoBlockKey,
  unionStableDedup,
  getStatePath,
  readStateOrInit,
  writeAtomic,
} = require("./shared");

function ensureAlertScheduled(state, sessionId, finding = null) {
  // Arming threshold: notice-severity findings do not arm alert mode.
  if (finding !== null && finding !== undefined && finding.severity === "notice") return;

  if (!state.alert || typeof state.alert !== "object" || Array.isArray(state.alert)) return;
  const phase = state.alert.alert_phase;
  if (phase === "done" || phase === "closed") return;

  if (phase !== "paused") {
    const plansDir = getWorkflowPlansDir();
    const candidates = new Set();
    if (sessionId && SESSION_ID_RE.test(sessionId)) candidates.add(sessionId);

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
    if (phase === "paused") {
      state.alert.alert_phase = "pending";
      state.alert.alert_retry_count = 0;
    }
  }
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

  // Class dedup: collapse same reporter+command block findings session-wide (after co-block
  // annotation). Class key = reporter + "|" + command; different reporters on the same command
  // are NOT collapsed (they are distinct hook actors and may form co-block sibling pairs above).
  // C4 intentional discard — subsequent findings of same class are NOT pushed; only
  // class_dedup_count on the first-occurrence finding is incremented.
  // C2 tradeoff: co_blocked_by mutations on sibling findings above are preserved even when the
  // new finding is discarded. Walk is O(n); bounded by notice+dedup keeping findings compact.
  const classCmd = extractCoBlockKey(newFinding.detail);
  if (classCmd !== newFinding.detail && typeof newFinding.reporter === "string") {
    const existingBlock = findings.find(
      (f) => f.reporter === newFinding.reporter && extractCoBlockKey(f.detail) === classCmd
    );
    if (existingBlock !== undefined) {
      existingBlock.class_dedup_count = (existingBlock.class_dedup_count || 1) + 1;
      ensureAlertScheduled(state, sessionId, finding);
      state.last_updated = nowIso;
      const vrDedup = validate(state);
      if (vrDedup.ok) writeAtomic(filePath, state);
      return true;
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

module.exports = { ensureAlertScheduled, appendFinding, readState };
