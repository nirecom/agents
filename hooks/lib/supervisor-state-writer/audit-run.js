"use strict";

// #2256 S2-g — audit run identity lifecycle: arm, finalize (compare-and-set),
// and block-override recording. Every entrypoint takes the state lock BEFORE
// its read, so a concurrent writer can never win a lost-update race.

const { withSessionStateLock } = require("./lock");
const { getStatePath, readStateOrInit, writeAtomic, SESSION_ID_RE } = require("./shared");
const { validate, validateFinding, UNSETTLED_AUDIT_PHASES } = require("../supervisor-state-schema");
const ledger = require("../audit-ledger");
const triggers = require("../audit-triggers");
const { computeFreshnessKey } = require("../diff-fingerprint");
const { computeWorkingTreeDiff, computeScopeDrift } = require("../branch-diff");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { snapshotDeclaredFiles, declaredFilesOf } = require("./declared-files");

const AUDIT_DEFAULTS = {
  run_seq: 0, audit_run_id: null, audit_verdict_summary: null, audit_dispatched_at: null,
  ledger: [], consumed_transitions: [], last_terminal_run_id: null,
  declared_files: null, uv_attempt_seq: 0, block_overrides: [],
  audit_run_counts: { TR1: 0, TR2: 0, TR3: 0 },
};

const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Defaults are copied per state: a shared default object would carry one
// session's counts into every other session read in the same process.
function auditOf(state) {
  if (!isPlainObject(state.audit)) state.audit = {};
  for (const [k, v] of Object.entries(AUDIT_DEFAULTS)) {
    if (state.audit[k] === undefined) state.audit[k] = Array.isArray(v) ? [] : isPlainObject(v) ? { ...v } : v;
  }
  if (!isPlainObject(state.audit.audit_run_counts)) state.audit.audit_run_counts = { ...AUDIT_DEFAULTS.audit_run_counts };
  for (const tr of Object.keys(AUDIT_DEFAULTS.audit_run_counts)) {
    if (state.audit.audit_run_counts[tr] === undefined) state.audit.audit_run_counts[tr] = 0;
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
  writeAtomic(getStatePath(sessionId, { forWrite: true }), state);
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

function armCore(sessionId, opts) {
  const state = readStateOrInit(sessionId);
  const audit = auditOf(state);

  // Idempotency guard: if an arm is already in flight, return the existing run rather
  // than minting a duplicate. Two concurrent Stop hooks that both evaluated the
  // pre-write snapshot call armAuditRun independently; the file lock serializes entry
  // into armCore, so the second Stop finds phase=pending and exits here (#2256 S2-c).
  // #2698 exception: a shown arm replaces an unshown run — no agent ever ran it, so the
  // finalize CAS cannot collide; its judgment set is carried into the new run.
  // #2534 exception: supersede_unsettled replaces even a shown or in_progress run — the caller
  // has decided that run cannot settle the current gate, so returning it would only re-hold.
  const prior = opts.supersede_unsettled === true ? ledger.inFlightRun(audit)
    : opts.launch_shown === true ? ledger.unshownRun(audit) : null;
  if (!prior && (audit.audit_phase === "pending" || audit.audit_phase === "in_progress")) {
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
  const subChecks = (opts.sub_checks || triggers.subChecksForTriggers(trIds)).slice();
  if (prior) {
    for (const t of prior.tr_ids) if (!trIds.includes(t)) trIds.push(t);
    for (const s of prior.sub_checks) if (!subChecks.includes(s)) subChecks.push(s);
    ledger.markLedgerEntrySuperseded(audit, prior.run_id, nowIso);
  }

  const freshness = opts.cwd
    ? computeFreshnessKey(opts.cwd, plansDir, planSessionId)
    : { input_version: null, artifact_keys: { intent: null, outline: null, detail: null }, freshness_key: null };

  // #2448: one diff feeds both the snapshot's diff scoping and the scope drift.
  const diff = opts.cwd ? computeWorkingTreeDiff(opts.cwd) : null;
  snapshotDeclaredFiles(audit, {
    trIds, runId, plansDir, planSessionId, nowIso,
    narrowed: opts.declared_files_narrowed === true,
    changedFiles: diff ? diff.changedFiles : null,
  });

  let scopeDrift = null;
  let inputBase = null;
  if (diff) {
    inputBase = diff.mergeBase;
    scopeDrift = computeScopeDrift(diff.changedFiles, declaredFilesOf(audit, plansDir, planSessionId));
  }

  const entry = {
    id: runId,
    tr_ids: trIds,
    cause: opts.cause || (prior && prior.cause) || null,
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
  // #2698: audit_dispatched_at = when the launch instruction was shown to the main conversation.
  audit.audit_dispatched_at = opts.launch_shown === true ? nowIso : null;
  ledger.appendLedgerEntry(audit, entry);
  ledger.extendConsumedTransitions(audit, entry.transitions);
  // #2795: only a newly minted run counts toward its stage's cap; the idempotent return above never does.
  if (typeof opts.count_tr === "string" && ledger.TR_ID_RE.test(opts.count_tr)) {
    const counts = audit.audit_run_counts;
    counts[opts.count_tr] = (Number.isInteger(counts[opts.count_tr]) ? counts[opts.count_tr] : 0) + 1;
  }

  const ok = commit(sessionId, state);
  const result = {
    ok,
    audit_run_id: runId,
    run_id: runId,
    run_seq: runSeq,
    freshness_key: entry.freshness_key,
    sub_checks: subChecks,
    scope_drift: scopeDrift,
  };
  if (prior) result.superseded_run_id = prior.run_id;
  return result;
}

// #2698: records that runId's launch instruction was shown. Matches on run-id as well as the
// unshown state, so a newer run armed meanwhile is never marked by mistake.
function markAuditLaunchShown(sessionId, runId) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId) || typeof runId !== "string") return false;
  const result = withSessionStateLock(sessionId, () => {
    const state = readStateOrInit(sessionId);
    const audit = auditOf(state);
    const run = ledger.unshownRun(audit);
    if (!run || run.run_id !== runId) return false;
    audit.audit_dispatched_at = new Date().toISOString();
    return commit(sessionId, state);
  });
  return result === true;
}

// Mints the next run identity inside the same read-modify-write that arms the
// slot — a separate numbering read would hand two Stops the same id.
function armAuditRun(sessionId, opts = {}) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return { ok: false, audit_run_id: null, run_id: null };
  const result = withSessionStateLock(sessionId, () => armCore(sessionId, opts));
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
  const result = withSessionStateLock(sessionId, () => finalizeCore(sessionId, opts));
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
  const result = withSessionStateLock(sessionId, () => {
    const state = readStateOrInit(sessionId);
    const audit = auditOf(state);
    ledger.extendConsumedTransitions(audit, transitions);
    return commit(sessionId, state);
  });
  return result === true;
}

function recordBlockOverride(sessionId, opts = {}) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  const result = withSessionStateLock(sessionId, () => {
    const state = readStateOrInit(sessionId);
    const audit = auditOf(state);
    const nowIso = new Date().toISOString();
    const orNull = (v) => (v === undefined ? null : v);
    // #2597: verdict + snapshot (artifact_keys, trigger_key) let the null-key path pin the acceptance.
    ledger.appendBlockOverride(audit, {
      run_id: orNull(opts.audit_run_id),
      verdict: orNull(opts.verdict),
      freshness_key: orNull(opts.freshness_key),
      artifact_keys: orNull(opts.artifact_keys),
      trigger_key: orNull(opts.trigger_key),
      reason: orNull(opts.reason),
      actor: orNull(opts.actor),
      recorded_at: nowIso,
    });
    // An acceptance overrules a standing BLOCK / WARN audit verdict; that is a governance act
    // worth an audit-trail finding, not a silent state edit.
    if (!state.layer1 || typeof state.layer1 !== "object" || Array.isArray(state.layer1)) state.layer1 = { findings: [] };
    if (!Array.isArray(state.layer1.findings)) state.layer1.findings = [];
    state.layer1.findings.push({
      severity: "warning",
      categories: ["workflow"],
      reporter: typeof opts.reporter === "string" && opts.reporter.length > 0 ? opts.reporter : "supervisor-block-override",
      detail: `block-override recorded for ${opts.audit_run_id || "<none>"} by ${opts.actor || "<unknown>"}: ${opts.reason || ""}`,
      reason: opts.reason === undefined ? null : opts.reason,
      timestamp: nowIso,
    });
    return commit(sessionId, state);
  });
  return result === true;
}

// #2795: RESET_FROM_<plan step> zeroes the audit run counts of that stage and
// later ones. Writes nothing when every named count is already 0.
function resetAuditRunCounts(sessionId, trIds) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId) || !Array.isArray(trIds)) return false;
  const result = withSessionStateLock(sessionId, () => {
    const state = readStateOrInit(sessionId);
    const counts = auditOf(state).audit_run_counts;
    const targets = trIds.filter((tr) => typeof tr === "string" && ledger.TR_ID_RE.test(tr) && counts[tr] !== 0);
    if (targets.length === 0) return true;
    for (const tr of targets) counts[tr] = 0;
    return commit(sessionId, state);
  });
  return result === true;
}

// #2853: the user accepted an unsettled run (UNSETTLED), so it will never get a
// verdict. Retire its ledger entry as discarded-stale and settle the phase to
// done, so the Phase A arm and the session-close gate stop waiting on it.
// Returns { released, reason }; only the currently armed, unsettled run is released.
function releaseUnsettledRun(sessionId, runId) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId) || typeof runId !== "string") return { released: false, reason: "invalid-args" };
  const result = withSessionStateLock(sessionId, () => {
    const state = readStateOrInit(sessionId);
    const audit = auditOf(state);
    if (runId !== audit.audit_run_id) return { released: false, reason: "identity-mismatch" };
    if (!UNSETTLED_AUDIT_PHASES.includes(audit.audit_phase)) return { released: false, reason: "not-unsettled" };
    const nowIso = new Date().toISOString();
    for (const entry of audit.ledger) {
      if (entry && entry.id === runId && entry.outcome !== "terminal") {
        entry.outcome = "discarded-stale";
        entry.terminal_at = nowIso;
      }
    }
    audit.audit_phase = "done";
    return commit(sessionId, state) ? { released: true, reason: null } : { released: false, reason: "commit-failed" };
  });
  return result === undefined ? { released: false, reason: "lock-unavailable" } : result;
}

module.exports = {
  armAuditRun, markAuditLaunchShown, consumeTransitions, finalizeAuditRun, recordBlockOverride,
  resetAuditRunCounts, releaseUnsettledRun, auditOf, AUDIT_DEFAULTS, inputKeyForSubCheck,
};
