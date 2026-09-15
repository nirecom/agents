"use strict";
// hooks/workflow-gate/supervisor-check.js
// #2256 S5-e — read-only pre-merge FRESHNESS BACKSTOP: arms nothing; at merge
// time only re-verifies a terminal TR5 run exists, is fresh, and is non-BLOCK.
// Its sole write is a layer1 anomaly finding when a fresh BLOCK verdict is being
// bypassed (Path i-b). `blockFn` is injected so this stays free of the hook's
// stdout protocol. TR5 arming lives in hooks/supervisor-guard +
// hooks/workflow-gate/user-verified-audit.js.

const os = require("os");

const {
  readState: readSupervisorState,
  appendFinding,
} = require("../lib/supervisor-state-writer");
const { resolveWorkflowSessionId } = require("../lib/resolve-workflow-session-id");
const { computeFreshnessKey } = require("../lib/diff-fingerprint");
const { parseDetailFilesToModify } = require("../lib/branch-diff");
const { formatFreshnessBackstopReason } = require("../lib/supervisor-report-format");
const { FRESHNESS_BACKSTOP_CAUSE } = require("../lib/audit-triggers");
const { resolveRepoDir } = require("./repo-resolution");

// Resolve supervisor state with wsid fallback.
// wsid is always resolved independently (even when state is found under the primary
// sessionId) so plan-artifact lookups (computeFreshnessKey, etc.) can use it regardless
// of which store holds the supervisor state (#2256 C12 / dual-ID session).
function resolveSupervisorState(sessionId) {
  try {
    let resolvedWsid = null;
    try {
      const w = resolveWorkflowSessionId();
      if (w) resolvedWsid = w;
    } catch (_) {}

    let state = readSupervisorState(sessionId);
    if (state) return { state, effectiveSid: sessionId, wsid: resolvedWsid };

    if (resolvedWsid) {
      state = readSupervisorState(resolvedWsid);
      if (state) return { state, effectiveSid: resolvedWsid, wsid: resolvedWsid };
    }
    return { state: null, effectiveSid: sessionId, wsid: resolvedWsid };
  } catch (e) {
    return { state: null, effectiveSid: sessionId, wsid: null };
  }
}

// The last terminal ledger entry that covers the user_verification trigger (TR5).
// A TR4-only (or any non-TR5) terminal run does not settle the pre-merge hold.
function lastTr5TerminalRun(audit) {
  const ledger = audit && Array.isArray(audit.ledger) ? audit.ledger : [];
  for (let i = ledger.length - 1; i >= 0; i--) {
    const e = ledger[i];
    if (!e || e.outcome !== "terminal") continue;
    if (Array.isArray(e.tr_ids) && e.tr_ids.includes("TR5")) return e;
  }
  return null;
}

// True when any terminal BLOCK entry appears in the ledger after the given index.
// Used to honour a later TR6 BLOCK that postdates the TR5 non-BLOCK run (#2256).
function hasLaterTerminalBlock(audit, afterIdx) {
  const ledger = audit && Array.isArray(audit.ledger) ? audit.ledger : [];
  for (let i = afterIdx + 1; i < ledger.length; i++) {
    const e = ledger[i];
    if (e && e.outcome === "terminal" && e.verdict === "BLOCK") return true;
  }
  return false;
}

// Which freshness components moved between the stored TR5 run and the current
// inputs. Real runs record a per-component breakdown (input_version +
// artifact_keys); a minimal seed carries only freshness_key, so we cannot point
// at one component and instead list every candidate.
function movedComponents(storedRun, current) {
  const moved = [];
  const cur = current || {};
  const curArtifacts = cur.artifact_keys || {};
  const hasBreakdown = storedRun &&
    (storedRun.input_version != null || (storedRun.artifact_keys && typeof storedRun.artifact_keys === "object"));
  if (hasBreakdown) {
    if (storedRun.input_version !== cur.input_version) moved.push("code diff (input_version)");
    const storedArtifacts = storedRun.artifact_keys || {};
    for (const name of ["intent", "outline", "detail"]) {
      if (storedArtifacts[name] !== curArtifacts[name]) moved.push(name);
    }
  }
  if (moved.length === 0) {
    moved.push("intent", "outline", "detail", "code diff (input_version)");
  }
  return moved;
}

// Read-only pre-merge freshness backstop.
// Returns { authoritative: true } when supervisor state resolves — the caller
// must then call approve() (a deny has already exited via blockFn). Returns
// { authoritative: false } when no supervisor state exists, so the caller falls
// through to the legacy workflow user_verification merge gate.
function checkSupervisorPreMerge(sessionId, mergeKind, hookCwd, opts = {}) {
  const blockFn = opts.blockFn;
  const resolveRepoDirFn = opts.resolveRepoDirFn || resolveRepoDir;

  let resolved;
  try {
    resolved = resolveSupervisorState(sessionId);
  } catch (e) {
    return { authoritative: false };
  }
  const { state, effectiveSid, wsid } = resolved;
  if (!state) return { authoritative: false };

  try {
    const audit = state.audit || {};
    const repoDir = hookCwd || resolveRepoDirFn(null, null);
    const plansDir = process.env.WORKFLOW_PLANS_DIR || (os.homedir() + "/.workflow-plans");

    // Plan artifact files are keyed by the workflow session id (wsid, the
    // timestamped prefix), not the supervisor state key (effectiveSid / CC uuid).
    // Use wsid when available so computeFreshnessKey finds the correct files (#2256 C8).
    const planSessionId = wsid || effectiveSid;

    // Recompute the current freshness key over working tree + plan artifacts.
    let current = null;
    try {
      current = computeFreshnessKey(repoDir, plansDir, planSessionId);
    } catch (_) {
      current = null;
    }
    const currentFk = current && current.freshness_key;

    const deny = (detailLine) => {
      blockFn(formatFreshnessBackstopReason(FRESHNESS_BACKSTOP_CAUSE, detailLine, sessionId, wsid, effectiveSid));
    };

    // Fail-closed: an uncomputable freshness key can never certify freshness.
    if (!currentFk) {
      deny("the freshness key could not be computed for this working tree (fail-closed).");
      return { authoritative: true };
    }

    const tr5Run = lastTr5TerminalRun(audit);
    if (!tr5Run) {
      deny("no terminal user_verification (TR5) audit run exists.");
      return { authoritative: true };
    }

    // A later non-TR5 (e.g. TR6) BLOCK that postdates the TR5 run must not be
    // silently bypassed when the TR5 run itself was non-BLOCK (#2256).
    const ledger = audit && Array.isArray(audit.ledger) ? audit.ledger : [];
    const tr5Idx = ledger.indexOf(tr5Run);
    if (tr5Idx >= 0 && hasLaterTerminalBlock(audit, tr5Idx)) {
      deny("a later audit BLOCK verdict (post-TR5) is unresolved.");
      return { authoritative: true };
    }

    if (tr5Run.freshness_key !== currentFk) {
      const moved = movedComponents(tr5Run, current);
      deny(`inputs moved since the TR5 verdict — changed: ${moved.join(", ")}.`);
      return { authoritative: true };
    }

    if (tr5Run.verdict === "BLOCK") {
      // Honor a recorded block override so USER_VERIFIED + merge can complete
      // end-to-end when the user has reviewed the BLOCK and accepted the risk.
      // The override must match the same run_id and freshness_key that the
      // user_verification gate checked (#2256 override end-to-end).
      const overrides = Array.isArray(audit.block_overrides) ? audit.block_overrides : [];
      const overrideActive = overrides.some((bo) =>
        bo && bo.run_id === tr5Run.id &&
        typeof bo.freshness_key === "string" && bo.freshness_key.length > 0 &&
        currentFk && bo.freshness_key === currentFk
      );
      if (overrideActive) {
        return { authoritative: true };
      }
      // Path (i-b), doubled safety net: a fresh BLOCK verdict must never reach
      // the merge. Record the bypass as a layer1 anomaly before denying.
      try {
        appendFinding(effectiveSid, {
          severity: "error",
          categories: ["workflow"],
          reporter: "freshness-backstop",
          detail: "TR5 hold bypassed: a fresh BLOCK user_verification verdict reached the pre-merge backstop",
          reason: "the user_verification audit returned BLOCK but a merge to a protected branch was still attempted",
        });
      } catch (_) {}
      deny("the last user_verification (TR5) verdict is BLOCK and is unresolved.");
      return { authoritative: true };
    }

    // Fresh, TR5-covered, non-BLOCK verdict: the merge may proceed.
    return { authoritative: true };
  } catch (e) {
    // Fail-closed once supervisor state is known to exist.
    try {
      blockFn(formatFreshnessBackstopReason(
        FRESHNESS_BACKSTOP_CAUSE,
        "the freshness backstop failed to evaluate (fail-closed).",
        sessionId, wsid, effectiveSid
      ));
    } catch (_) {}
    return { authoritative: true };
  }
}

module.exports = {
  checkSupervisorPreMerge,
  parseDetailFilesToModify,
  resolveSupervisorState,
  lastTr5TerminalRun,
  hasLaterTerminalBlock,
  movedComponents,
};
