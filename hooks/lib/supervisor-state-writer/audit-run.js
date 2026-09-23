"use strict";

// #2256 S2-g — audit run identity lifecycle: arm, finalize (compare-and-set),
// and block-override recording. Every entrypoint takes the state lock BEFORE
// its read, so a concurrent writer can never win a lost-update race.

const { withStateLock } = require("./lock");
const { getStatePath, readStateOrInit, writeAtomic, SESSION_ID_RE } = require("./shared");
const { validate, validateFinding } = require("../supervisor-state-schema");
const ledger = require("../audit-ledger");
const triggers = require("../audit-triggers");
const { computeFreshnessKey } = require("../diff-fingerprint");
const { computeWorkingTreeDiff, computeScopeDrift, parseDetailFilesToModify } = require("../branch-diff");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");

const AUDIT_DEFAULTS = {
  run_seq: 0, audit_run_id: null, audit_verdict_summary: null, audit_dispatched_at: null,
  ledger: [], consumed_transitions: [], last_terminal_run_id: null,
  declared_files: null, uv_attempt_seq: 0, block_overrides: [],
};

function auditOf(state) {
  if (!state.audit || typeof state.audit !== "object" || Array.isArray(state.audit)) state.audit = {};
  for (const [k, v] of Object.entries(AUDIT_DEFAULTS)) {
    if (state.audit[k] === undefined) state.audit[k] = Array.isArray(v) ? [] : v;
  }
  return state.audit;
}

function commit(sessionId, state) {
  state.last_updated = new Date().toISOString();
  const vr = validate(state);
  if (!vr.ok) {
    console.error(`[supervisor-state-writer] audit-run validate failed: ${vr.errors.join("; ")}`);
    return false;
  }
  writeAtomic(getStatePath(sessionId), state);
  return true;
}

// Sub-check input keys: plan-artifact sub-checks key off their artifact digest,
// diff sub-checks off the working-tree input version.
function buildInputKeys(subCheckIds, freshness, planSessionId, plansDir) {
  const { computeArtifactKey } = require("../diff-fingerprint");
  const keys = {};
  for (const id of subCheckIds) {
    const spec = triggers.SUB_CHECKS[id];
    if (!spec) continue;
    // Every armed sub-check gets an entry, null included: a missing key and an
    // uncomputable key are different facts, and dedup must be able to tell them
    // apart rather than read "absent" as "never armed".
    keys[id] = inputKeyForSubCheck(id, spec, freshness, planSessionId, plansDir);
  }
  return keys;
}

// One rule for the current input key of a sub-check, shared by arm and the TR5
// gate so a run this arms is recognized as settled by the gate that reads it.
// recurrence-patterns is the whole-tree freshness question, so it keys off the
// composite freshness_key (code + all plan artifacts), never input_version
// alone; the other diff sub-checks key off input_version; artifact sub-checks
// key off the digest of their named artifacts.
function inputKeyForSubCheck(id, spec, freshness, planSessionId, plansDir) {
  const { computeArtifactKey } = require("../diff-fingerprint");
  let key;
  if (id === "recurrence-patterns") {
    key = freshness.freshness_key;
  } else if (spec.input === "diff") {
    key = freshness.input_version;
  } else {
    key = computeArtifactKey(plansDir, planSessionId, spec.artifacts);
  }
  return typeof key === "string" && key.length > 0 ? key : null;
}

// Per-trigger metadata only — never read by dedup, which keys on input_key.
function buildTriggerInputKeys(trIds, freshness, planSessionId, plansDir) {
  const { computeArtifactKey } = require("../diff-fingerprint");
  const keys = {};
  for (const trId of trIds) {
    const trigger = triggers.triggerById(trId);
    if (!trigger) continue;
    const specs = trigger.sub_checks.map((id) => triggers.SUB_CHECKS[id]).filter(Boolean);
    if (specs.some((s) => s.input === "diff")) {
      keys[trId] = freshness.input_version;
      continue;
    }
    const artifacts = [];
    for (const s of specs) {
      for (const a of s.artifacts) if (!artifacts.includes(a)) artifacts.push(a);
    }
    const key = artifacts.length > 0 ? computeArtifactKey(plansDir, planSessionId, artifacts) : null;
    keys[trId] = typeof key === "string" && key.length > 0 ? key : null;
  }
  return keys;
}

function declaredFilesOf(audit, plansDir, planSessionId) {
  const snapshot = audit.declared_files;
  if (snapshot && Array.isArray(snapshot.files) && snapshot.files.length > 0) return snapshot.files;
  return parseDetailFilesToModify(plansDir, planSessionId);
}

// S3-d: detail completion (TR3) snapshots detail.md's declared file set. The
// detail artifact key travels with it because a later detail.md edit arms no
// new run — only that key can reveal the snapshot has gone stale.
function snapshotDeclaredFiles(audit, trIds, runId, plansDir, planSessionId, nowIso, narrowed) {
  // TR3 seeds the snapshot; a later narrowing (declared_files_narrowed) refreshes
  // it to the current detail.md set so scope drift is judged against what the
  // plan now declares, not the wider set the first snapshot froze.
  if (!trIds.includes("TR3") && narrowed !== true) return;
  const { computeArtifactKey } = require("../diff-fingerprint");
  const detailKey = computeArtifactKey(plansDir, planSessionId, ["intent", "outline", "detail"]);
  audit.declared_files = ledger.capDeclaredFiles({
    snapshot_at: nowIso,
    run_id: runId,
    detail_key: typeof detailKey === "string" && detailKey.length > 0 ? detailKey : null,
    files: parseDetailFilesToModify(plansDir, planSessionId),
  });
}

function armCore(sessionId, opts) {
  const state = readStateOrInit(sessionId);
  const audit = auditOf(state);

  // Idempotency guard: if an arm is already in flight, return the existing run rather
  // than minting a duplicate. Two concurrent Stop hooks that both evaluated the
  // pre-write snapshot call armAuditRun independently; the file lock serializes entry
  // into armCore, so the second Stop finds phase=pending and exits here (#2256 S2-c).
  if (audit.audit_phase === "pending" || audit.audit_phase === "in_progress") {
    return {
      ok: true,
      audit_run_id: audit.audit_run_id,
      run_id: audit.audit_run_id,
      run_seq: audit.run_seq || 0,
      freshness_key: null,
      sub_checks: Array.isArray(audit.pending_sub_checks) ? audit.pending_sub_checks.slice() : [],
      scope_drift: null,
    };
  }

  const runSeq = (Number.isInteger(audit.run_seq) ? audit.run_seq : 0) + 1;
  const runId = ledger.formatRunId(runSeq);
  const nowIso = new Date().toISOString();

  const plansDir = opts.plans_dir || getWorkflowPlansDir();
  const planSessionId = opts.plan_session_id || sessionId;
  const trIds = Array.isArray(opts.tr_ids) ? opts.tr_ids.slice() : [];
  const subChecks = opts.sub_checks || triggers.subChecksForTriggers(trIds);

  const freshness = opts.cwd
    ? computeFreshnessKey(opts.cwd, plansDir, planSessionId)
    : { input_version: null, artifact_keys: { intent: null, outline: null, detail: null }, freshness_key: null };

  snapshotDeclaredFiles(audit, trIds, runId, plansDir, planSessionId, nowIso, opts.declared_files_narrowed === true);

  let scopeDrift = null;
  let inputBase = null;
  if (opts.cwd) {
    const diff = computeWorkingTreeDiff(opts.cwd);
    if (diff) {
      inputBase = diff.mergeBase;
      scopeDrift = computeScopeDrift(diff.changedFiles, declaredFilesOf(audit, plansDir, planSessionId));
    }
  }

  const entry = {
    id: runId,
    tr_ids: trIds,
    cause: opts.cause || null,
    transitions: Array.isArray(opts.transitions) ? opts.transitions.slice() : [],
    input_version: freshness.input_version,
    input_base: inputBase,
    input_key: buildInputKeys(subChecks, freshness, planSessionId, plansDir),
    trigger_input_keys: opts.trigger_input_keys || buildTriggerInputKeys(trIds, freshness, planSessionId, plansDir),
    artifact_keys: freshness.artifact_keys,
    freshness_key: freshness.freshness_key,
    declared_files_narrowed: opts.declared_files_narrowed === true,
    sub_checks: subChecks,
    scope_drift: scopeDrift,
    verdict: null,
    verdict_summary: null,
    outcome: "armed",
    armed_at: nowIso,
    terminal_at: null,
  };

  audit.run_seq = runSeq;
  audit.audit_run_id = runId;
  // pending_sub_checks names what this armed run must still judge. The schema
  // validate() tolerates this unknown key; writeAuditState's patch allowlist does
  // not, so it can only be set here, on the commit() path.
  audit.pending_sub_checks = subChecks.slice();
  audit.audit_phase = "pending";
  audit.audit_armed_at = nowIso;
  audit.audit_cause = entry.cause;
  audit.audit_retry_count = 0;
  audit.audit_verdict = null;
  audit.audit_verdict_summary = null;
  audit.audit_dispatched_at = null;
  ledger.appendLedgerEntry(audit, entry);
  ledger.extendConsumedTransitions(audit, entry.transitions);

  const ok = commit(sessionId, state);
  return {
    ok,
    audit_run_id: runId,
    run_id: runId,
    run_seq: runSeq,
    freshness_key: entry.freshness_key,
    sub_checks: subChecks,
    scope_drift: scopeDrift,
  };
}

// Mints the next run identity inside the same read-modify-write that arms the
// slot — a separate numbering read would hand two Stops the same id.
function armAuditRun(sessionId, opts = {}) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return { ok: false, audit_run_id: null, run_id: null };
  const result = withStateLock(getStatePath(sessionId), () => armCore(sessionId, opts));
  return result === undefined ? { ok: false, audit_run_id: null, run_id: null } : result;
}

function staleFinalizeFinding(runId, currentRunId, phase) {
  return {
    severity: "warning",
    categories: ["workflow"],
    reporter: "supervisor-audit-finalize",
    detail: `audit verdict discarded: run ${runId} is not the armed run (current ${currentRunId}, phase ${phase})`,
    reason: "compare-and-set rejected a verdict written for a superseded audit run",
    timestamp: new Date().toISOString(),
  };
}

function finalizeCore(sessionId, opts) {
  const state = readStateOrInit(sessionId);
  const audit = auditOf(state);
  const runId = opts.audit_run_id;
  const phase = audit.audit_phase;
  const accepted = typeof runId === "string" && runId === audit.audit_run_id &&
    (phase === "pending" || phase === "in_progress");

  if (!accepted) {
    ledger.appendLedgerEntry(audit, {
      id: typeof runId === "string" ? runId : null,
      tr_ids: [], cause: null, transitions: [],
      verdict: opts.verdict === undefined ? null : opts.verdict,
      verdict_summary: opts.verdict_summary === undefined ? null : opts.verdict_summary,
      outcome: "discarded-stale",
      armed_at: null,
      terminal_at: new Date().toISOString(),
      sub_checks: [], input_key: {},
    });
    if (state.layer1 && Array.isArray(state.layer1.findings)) {
      state.layer1.findings.push(staleFinalizeFinding(runId, audit.audit_run_id, phase));
    }
    commit(sessionId, state);
    return { accepted: false, reason: "identity-mismatch", audit_run_id: audit.audit_run_id };
  }

  const nowIso = new Date().toISOString();
  audit.audit_verdict = opts.verdict === undefined ? null : opts.verdict;
  audit.audit_verdict_summary = opts.verdict_summary === undefined ? null : opts.verdict_summary;
  audit.audit_phase = "done";
  audit.audit_last_run_at = nowIso;
  audit.audit_retry_count = 0;
  audit.last_terminal_run_id = runId;
  // #929: findings generated by the audit codex engine are merged in the SAME
  // CAS-success commit as the verdict. Only the armed identity reaches here, so a
  // stale run can never leak findings (they never touch the identity-mismatch path).
  if (Array.isArray(opts.findings) && opts.findings.length > 0) {
    if (!Array.isArray(audit.findings)) audit.findings = [];
    const nowFind = new Date().toISOString();
    for (const f of opts.findings) {
      const vr = validateFinding(f);
      if (!vr.ok) continue;
      audit.findings.push(Object.assign({ reporter: "supervisor-audit", timestamp: nowFind }, f));
    }
  }
  for (const entry of audit.ledger) {
    if (entry && entry.id === runId) {
      entry.outcome = "terminal";
      entry.verdict = audit.audit_verdict;
      entry.verdict_summary = audit.audit_verdict_summary;
      entry.terminal_at = nowIso;
    }
  }
  ledger.pruneLedger(audit);
  const ok = commit(sessionId, state);
  return { accepted: ok, audit_run_id: runId };
}

// Compare-and-set: only the identity currently armed may write a verdict.
function finalizeAuditRun(sessionId, opts = {}) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return { accepted: false, reason: "invalid-session" };
  const result = withStateLock(getStatePath(sessionId), () => finalizeCore(sessionId, opts));
  return result === undefined ? { accepted: false, reason: "lock-unavailable" } : result;
}

// S6-b no-op path: when every in-scope sub-check is already settled the Stop
// hook arms nothing, but the fired edge transition(s) must still be recorded as
// consumed — otherwise the same transition re-arms on the next Stop. This is the
// one writer of consumed_transitions off the arm path (writeAuditState's patch
// allowlist deliberately excludes the key, so it can only be set here).
function consumeTransitions(sessionId, transitions) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  if (!Array.isArray(transitions) || transitions.length === 0) return true;
  const result = withStateLock(getStatePath(sessionId), () => {
    const state = readStateOrInit(sessionId);
    const audit = auditOf(state);
    ledger.extendConsumedTransitions(audit, transitions);
    return commit(sessionId, state);
  });
  return result === true;
}

function recordBlockOverride(sessionId, opts = {}) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  const result = withStateLock(getStatePath(sessionId), () => {
    const state = readStateOrInit(sessionId);
    const audit = auditOf(state);
    const nowIso = new Date().toISOString();
    ledger.appendBlockOverride(audit, {
      run_id: opts.audit_run_id === undefined ? null : opts.audit_run_id,
      freshness_key: opts.freshness_key === undefined ? null : opts.freshness_key,
      reason: opts.reason === undefined ? null : opts.reason,
      actor: opts.actor === undefined ? null : opts.actor,
      recorded_at: nowIso,
    });
    // An override overrules a standing BLOCK audit hold; that is a governance act
    // worth an audit-trail finding, not a silent state edit.
    if (!state.layer1 || typeof state.layer1 !== "object" || Array.isArray(state.layer1)) state.layer1 = { findings: [] };
    if (!Array.isArray(state.layer1.findings)) state.layer1.findings = [];
    state.layer1.findings.push({
      severity: "warning",
      categories: ["workflow"],
      reporter: "supervisor-record-block-override",
      detail: `block-override recorded for ${opts.audit_run_id || "<none>"} by ${opts.actor || "<unknown>"}: ${opts.reason || ""}`,
      reason: opts.reason === undefined ? null : opts.reason,
      timestamp: nowIso,
    });
    return commit(sessionId, state);
  });
  return result === true;
}

module.exports = { armAuditRun, consumeTransitions, finalizeAuditRun, recordBlockOverride, auditOf, AUDIT_DEFAULTS, inputKeyForSubCheck };
