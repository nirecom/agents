"use strict";
// hooks/workflow-gate/user-verified-audit.js
// #2256 S5-b/S5-c — the TR5 user_verification audit gate. Two stages sit in
// front of the <<WORKFLOW_USER_VERIFIED>> sentinel. Stage 1: a standing BLOCK
// verdict holds the sentinel (fail-closed) until a fresh non-BLOCK run or a
// recorded override for this exact run + freshness clears it. Stage 2: a diff-
// based re-audit approves only when every sub-check the last TR5 run covered is
// still fresh, and otherwise arms the sub-checks that moved. approveFn/blockFn
// are injected so this module stays free of the hook's stdout protocol.

const os = require("os");

const { resolveSupervisorState, lastTr5TerminalRun, hasLaterTerminalBlock } = require("./supervisor-check");
const { computeFreshnessKey } = require("../lib/diff-fingerprint");
const { parseDetailFilesToModify } = require("../lib/branch-diff");
const { armAuditRun, inputKeyForSubCheck } = require("../lib/supervisor-state-writer/audit-run");
const { isSubCheckSettled } = require("../lib/audit-ledger");
const {
  SUB_CHECKS,
  ALL_SUB_CHECK_IDS,
  triggerById,
  stepCompleteCause,
} = require("../lib/audit-triggers");
const { NON_BLOCK_TERMINAL_VERDICTS } = require("../lib/supervisor-state-schema");

const TR_RANK = { TR1: 1, TR2: 2, TR3: 3, TR4: 4, TR5: 5, TR6: 6 };

function plansDirOf() {
  return process.env.WORKFLOW_PLANS_DIR || (os.homedir() + "/.workflow-plans");
}

// An override releases the hold only while it still names the run it was taken
// against AND the working tree has not moved since (freshness_key pin).
function overrideReleases(audit, tr5Run, currentFk) {
  const overrides = Array.isArray(audit.block_overrides) ? audit.block_overrides : [];
  for (const bo of overrides) {
    if (!bo) continue;
    if (bo.run_id !== tr5Run.id) continue;
    if (typeof bo.freshness_key !== "string" || bo.freshness_key.length === 0) continue;
    if (currentFk && bo.freshness_key === currentFk) return true;
  }
  return false;
}

// The declared-files snapshot has gone stale when it was truncated, or when the
// current detail.md declares fewer files than the snapshot froze (a narrowing).
// Either forces a full re-audit rather than a sub-check-scoped one.
function snapshotStale(audit, plansDir, planSessionId) {
  const snap = audit.declared_files;
  if (!snap || typeof snap !== "object") return { truncated: false, narrowed: false };
  const truncated = snap.truncated === true;
  let narrowed = false;
  if (Array.isArray(snap.files) && snap.files.length > 0) {
    const current = parseDetailFilesToModify(plansDir, planSessionId) || [];
    narrowed = snap.files.some((f) => !current.includes(f));
  }
  return { truncated, narrowed };
}

// The judgment set an arm must cover: TR5's own sub-checks, plus every sub-check
// whose earliest trigger is at or before TR5 that is not currently settled.
function armJudgmentSet(audit, freshness, planSessionId, plansDir) {
  const own = new Set(triggerById("TR5").sub_checks);
  return ALL_SUB_CHECK_IDS.filter((id) => {
    if (own.has(id)) return true;
    const spec = SUB_CHECKS[id];
    if (!spec || TR_RANK[spec.earliest_tr] > TR_RANK.TR5) return false;
    const key = inputKeyForSubCheck(id, spec, freshness, planSessionId, plansDir);
    return !isSubCheckSettled(audit, id, key);
  });
}

// Approve only when every sub-check the last TR5 run covered is still fresh.
function coveredSetSettled(audit, tr5Run, freshness, planSessionId, plansDir) {
  const covered = Array.isArray(tr5Run.sub_checks) ? tr5Run.sub_checks : [];
  // Fail-closed: a terminal TR5 run that covered nothing must never be waved
  // through on a vacuous "all-settled". An empty covered set is a malformed or
  // corrupted terminal record, not a clean audit — returning false forces a
  // re-audit here, symmetric to the first-run arm (no run → arm the full set)
  // and consistent with this module's stated fail-closed invariant (#2256 C3).
  if (covered.length === 0) return false;
  for (const id of covered) {
    const spec = SUB_CHECKS[id];
    if (!spec) return false;
    const key = inputKeyForSubCheck(id, spec, freshness, planSessionId, plansDir);
    if (!isSubCheckSettled(audit, id, key)) return false;
  }
  return true;
}

function holdReason() {
  return [
    "[EM Supervisor] user_verification (TR5) audit hold: the last verdict is BLOCK and is unresolved.",
    "The recorded BLOCK stands while the code and plan artifacts are unchanged.",
    "Resolve by addressing the audit findings and re-running the user_verification audit,",
    "or record a reviewed override:",
    "  bin/supervisor-record-block-override <run-id> <reason> --session-id <sid>",
  ].join("\n");
}

function armReason(armResult) {
  const runId = (armResult && (armResult.run_id || armResult.audit_run_id)) || "<none>";
  const subChecks = armResult && Array.isArray(armResult.sub_checks) ? armResult.sub_checks.join(", ") : "";
  return [
    "[EM Supervisor] user_verification (TR5) audit required before the sentinel is accepted.",
    `An audit run has been armed (${runId}${subChecks ? `: ${subChecks}` : ""}).`,
    "Run agents/supervisor-audit.md as a subagent, then re-issue the sentinel.",
  ].join("\n");
}

// TR5 user_verification audit gate. Returns { authoritative: false } when no
// supervisor state exists (the caller then keeps its legacy behavior). When it
// is authoritative it has already called approveFn or blockFn, both of which
// exit; the returned { authoritative: true } is a formality.
function checkUserVerifiedAudit(sessionId, hookCwd, opts = {}) {
  const approveFn = opts.approveFn;
  const blockFn = opts.blockFn;

  // Defense layer (#2319): a null CWD reaches computeFreshnessKey → freshness_key:null
  // → infinite TR5 arm. The primary fix is workflow-gate.js Step 1; this is
  // defense-in-depth for any other null-CWD path.
  const cwd = hookCwd || process.cwd();

  let resolved;
  try {
    resolved = resolveSupervisorState(sessionId);
  } catch (e) {
    return { authoritative: false };
  }
  const { state: rawState, effectiveSid } = resolved;
  // C1: a missing supervisor state must not silently skip TR5 — fail-closed once
  // the resolver succeeds (state=null means fresh session, not "skip audit").
  const state = rawState || {};

  try {
    const audit = state.audit || {};
    const plansDir = plansDirOf();

    // effectiveSid is the supervisor state key (CC uuid). Plan artifact files
    // are keyed by the workflow session id (timestamped prefix), which differs
    // from the CC uuid. Resolve the workflow session id for artifact lookups so
    // computeFreshnessKey / snapshotStale / coveredSetSettled find the correct
    // files, rather than permanently failing with an empty freshness_key (#2256 C8).
    let planSessionId = effectiveSid;
    try {
      const envWsid = process.env.WORKFLOW_SESSION_ID;
      if (envWsid && /^[A-Za-z0-9_-]+$/.test(envWsid)) {
        planSessionId = envWsid;
      } else {
        const { resolveWorkflowSessionId } = require("../lib/resolve-workflow-session-id");
        const wsid = resolveWorkflowSessionId({});
        if (wsid) planSessionId = wsid;
      }
    } catch (_) {}

    let freshness = null;
    try {
      freshness = computeFreshnessKey(cwd, plansDir, planSessionId);
    } catch (_) {
      freshness = null;
    }
    const currentFk = freshness && freshness.freshness_key;

    const arm = (subCheckIds, narrowed) => {
      const result = armAuditRun(effectiveSid, {
        tr_ids: ["TR5"],
        cause: stepCompleteCause("user_verification"),
        cwd: cwd,
        plans_dir: plansDir,
        plan_session_id: planSessionId,
        sub_checks: subCheckIds,
        declared_files_narrowed: narrowed === true,
      });
      blockFn(armReason(result));
      return { authoritative: true };
    };

    const tr5Run = lastTr5TerminalRun(audit);

    // Stage 1 — a standing BLOCK verdict holds the sentinel (fail-closed).
    // Also block when a later non-TR5 (e.g. TR6) BLOCK postdates the TR5 non-BLOCK run;
    // without this, a fresh non-BLOCK TR5 followed by TR6 BLOCK would still call
    // approveFn and bypass the audit gate (#2256 C13 sibling of supervisor-check.js fix).
    const tr5AuditLedger = state.audit ? (state.audit.ledger || []) : [];
    const tr5Idx = tr5Run ? tr5AuditLedger.indexOf(tr5Run) : -1;
    const laterBlockExists = tr5Run && tr5Idx >= 0 && hasLaterTerminalBlock(state.audit, tr5Idx);

    // #2323 self-recovering short-circuit: when the code-side freshness_key cannot be
    // computed (input_version === null, e.g. no merge-base / detached HEAD / shallow
    // clone), re-arming on every emission creates an infinite loop. Approve the sentinel
    // instead when the last TR5 terminal run is in the explicit allow-list (CONTINUE only),
    // no later standing BLOCK exists, and the null is specifically a code-side null
    // (input_version null — not an artifact-side null, which stays fail-closed).
    const nonBlockTerminal = tr5Run && NON_BLOCK_TERMINAL_VERDICTS.includes(tr5Run.verdict);
    const codeSideUncomputable = freshness && freshness.freshness_key == null && freshness.input_version == null;
    const selfRecovering = nonBlockTerminal && !laterBlockExists && codeSideUncomputable;

    if (tr5Run && (tr5Run.verdict === "BLOCK" || laterBlockExists)) {
      // An override can only release a BLOCK carried by the TR5 run itself,
      // and only when no later TR6 BLOCK exists. A later BLOCK is an independent
      // run the TR5 override never speaks to — approving over it would bypass
      // that BLOCK entirely (#2256 C13/C22 override scope + later-block guard).
      if (!laterBlockExists && tr5Run.verdict === "BLOCK" && overrideReleases(audit, tr5Run, currentFk)) {
        approveFn();
        return { authoritative: true };
      }
      // selfRecovering is structurally always false here (BLOCK verdict or laterBlockExists
      // guarantees nonBlockTerminal=false or !laterBlockExists=false), so this check never
      // fires; it is present for CPR-ORTH symmetry with Stage 2 so both null-arm sites
      // share identical guards and future restructuring cannot leave one unprotected.
      if (!currentFk) {
        if (selfRecovering) { approveFn(); return { authoritative: true }; }
        return arm(ALL_SUB_CHECK_IDS.slice(), false);
      }
      if (tr5Run.freshness_key === currentFk) {
        blockFn(holdReason());
        return { authoritative: true };
      }
      return arm(ALL_SUB_CHECK_IDS.slice(), false);
    }

    // Stage 2 — diff-based re-audit for a missing/non-BLOCK terminal run.
    if (!tr5Run) return arm(ALL_SUB_CHECK_IDS.slice(), false);
    if (!currentFk) {
      // Primary fix for #2323: a null code-side freshness_key would otherwise re-arm
      // the WE-8 sentinel on every emission, looping forever. When selfRecovering is
      // true (CONTINUE terminal + no later BLOCK + input_version null), approve instead.
      if (selfRecovering) { approveFn(); return { authoritative: true }; }
      return arm(ALL_SUB_CHECK_IDS.slice(), false);
    }

    const { truncated, narrowed } = snapshotStale(audit, plansDir, planSessionId);
    if (truncated || narrowed) return arm(ALL_SUB_CHECK_IDS.slice(), true);

    if (coveredSetSettled(audit, tr5Run, freshness, planSessionId, plansDir)) {
      approveFn();
      return { authoritative: true };
    }

    return arm(armJudgmentSet(audit, freshness, planSessionId, plansDir), false);
  } catch (e) {
    // Fail-closed once supervisor state is known to exist: an unexpected error
    // must never wave an unaudited user_verification through.
    try {
      blockFn(
        "[EM Supervisor] user_verification (TR5) audit gate failed to evaluate — blocked (fail-closed)."
      );
    } catch (_) { /* stdout already emitted */ }
    return { authoritative: true };
  }
}

module.exports = {
  checkUserVerifiedAudit,
  overrideReleases,
  snapshotStale,
  armJudgmentSet,
  coveredSetSettled,
};
