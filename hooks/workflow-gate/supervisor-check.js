"use strict";
// hooks/workflow-gate/supervisor-check.js
// Supervisor pre-merge gate extracted from hooks/workflow-gate.js (file-split HARD limit).
// Owns the warning-flush (Path i), audit-verdict (Path i-b) and scope-drift (Path ii)
// checks that run just before a merge to a protected branch.
//
// The blocking primitive is injected (`blockFn`) rather than imported: workflow-gate.js
// owns the hook's stdout protocol and passes its own `blockWithoutError`.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

const { readState: readSupervisorState, writeAuditState } = require("../lib/supervisor-state-writer");
const { resolveWorkflowSessionId } = require("../lib/resolve-workflow-session-id");
const { formatPreMergeBlockReason } = require("../lib/supervisor-report-format");
const { AUDIT_SEVERITY_THRESHOLD, SEVERITY_RANK } = require("../lib/supervisor-state-schema");
const { getProtectedBranches } = require("../lib/merge-detect");
const { resolveRepoDir } = require("./repo-resolution");

// Resolve supervisor state with wsid fallback.
function resolveSupervisorState(sessionId) {
  try {
    let state = readSupervisorState(sessionId);
    if (state) return { state, effectiveSid: sessionId, wsid: null };
    const wsid = resolveWorkflowSessionId();
    if (wsid) {
      state = readSupervisorState(wsid);
      if (state) return { state, effectiveSid: wsid, wsid };
    }
    return { state: null, effectiveSid: sessionId, wsid: null };
  } catch (e) {
    return { state: null, effectiveSid: sessionId, wsid: null };
  }
}

// Resolve branch diff (changed files relative to the merge base with a protected branch).
function resolveBranchDiff(repoDir) {
  try {
    if (!repoDir) return null;
    const branches = getProtectedBranches();
    let mergeBase = null;
    for (const b of branches) {
      const r = spawnSync("git", ["merge-base", "origin/" + b, "HEAD"], { cwd: repoDir, encoding: "utf8" });
      if (r.status === 0 && r.stdout && r.stdout.trim()) {
        mergeBase = r.stdout.trim();
        break;
      }
    }
    if (!mergeBase) return null;
    const r = spawnSync("git", ["diff", "--name-only", mergeBase + "...HEAD"], { cwd: repoDir, encoding: "utf8" });
    if (r.status !== 0) return null;
    return (r.stdout || "").split("\n").map(p => p.trim().replace(/\\/g, "/")).filter(Boolean);
  } catch (e) {
    return null;
  }
}

// Parse declared "Files to modify" from the detail plan.
function parseDetailFilesToModify(plansDir, wsid) {
  try {
    if (!plansDir || !wsid) return null;
    const detailPath = path.join(plansDir, wsid + "-detail.md");
    let text;
    try { text = fs.readFileSync(detailPath, "utf8"); } catch (e) { return null; }
    const lines = text.split(/\r?\n/);
    let inSection = false;
    const paths = [];
    for (const line of lines) {
      if (line.trim() === "## Files to modify") { inSection = true; continue; }
      if (inSection && /^## /.test(line)) break;
      if (inSection) {
        const m = line.match(/`([^`]+)`/);
        if (m) paths.push(m[1].replace(/\\/g, "/"));
      }
    }
    return paths;
  } catch (e) {
    return null;
  }
}

// Returns true when the audit has seen all current findings (audit_last_run_at >= newest
// finding timestamp) and the verdict is non-BLOCK. A fresh non-BLOCK verdict means the
// audit already reviewed everything and approved or warned without blocking — so the
// warning-flush path should be skipped (#1374).
function isAuditVerdictFresh(auditState, alertFindings) {
  if (!auditState) return false;
  const verdict = auditState.audit_verdict;
  if (!verdict || verdict === "BLOCK") return false;
  const lastRunAt = auditState.audit_last_run_at;
  if (lastRunAt == null) return false;
  const lastRunMs = new Date(lastRunAt).getTime();
  if (Number.isNaN(lastRunMs)) return false;
  const findings = Array.isArray(alertFindings) ? alertFindings : [];
  if (findings.length === 0) return true;
  const newestFindingMs = Math.max(
    ...findings.map((f) => (f && f.timestamp ? new Date(f.timestamp).getTime() : 0))
  );
  return Number.isFinite(newestFindingMs) && lastRunMs >= newestFindingMs;
}

// Returns true only for BLOCK verdict — the one verdict that always gates the merge (#1374).
function shouldBlockOnAuditVerdict(auditState, alertFindings) {
  if (!auditState) return false;
  return auditState.audit_verdict === "BLOCK";
}

// Supervisor pre-merge gate: warning-flush and scope-drift checks.
// hookCwd: resolved cwd from the hook payload (toolInput.cwd) — allows
// resolveBranchDiff to target the actual repo being merged, not process.cwd().
// opts.blockFn: injected block primitive (workflow-gate.js passes blockWithoutError).
// opts.resolveRepoDirFn: injected repo resolver (defaults to repo-resolution's).
function checkSupervisorPreMerge(sessionId, mergeKind, hookCwd, opts = {}) {
  const blockFn = opts.blockFn;
  const resolveRepoDirFn = opts.resolveRepoDirFn || resolveRepoDir;
  try {
    const { state, effectiveSid, wsid } = resolveSupervisorState(sessionId);

    // Path (i): warning flush — block when cumSev >= threshold and findings exist.
    // Dual-store (C5): when CC UUID state has no alert findings, also check wsid state.
    // CC UUID state may be empty while a wsid session has active warnings.
    let alertState = state;
    let alertEffectiveSid = effectiveSid;
    let alertWsid = wsid;
    const ccHasFindings = state && state.alert &&
      Array.isArray(state.alert.findings) && state.alert.findings.length > 0;
    if (!ccHasFindings) {
      const wsidToTry = wsid || (() => {
        const env = process.env.WORKFLOW_SESSION_ID;
        if (env && /^[A-Za-z0-9_-]+$/.test(env)) return env;
        try { return resolveWorkflowSessionId(); } catch (_) { return null; }
      })();
      if (wsidToTry && wsidToTry !== sessionId) {
        const wsidState = readSupervisorState(wsidToTry);
        if (wsidState) { alertState = wsidState; alertEffectiveSid = wsidToTry; alertWsid = wsidToTry; }
      }
    }
    if (alertState) {
      const cumSev = alertState.alert && alertState.alert.cumulative_severity;
      const findings = (alertState.alert && Array.isArray(alertState.alert.findings) ? alertState.alert.findings : []);
      if (cumSev && SEVERITY_RANK[cumSev] >= SEVERITY_RANK[AUDIT_SEVERITY_THRESHOLD] && findings.length > 0) {
        const au = alertState.audit || {};
        const skip = au.audit_phase === "pending" || au.audit_phase === "in_progress" ||
          (au.audit_last_run_at != null && au.audit_cause === "pre-merge-warning-flush") ||
          isAuditVerdictFresh(au, findings);
        if (!skip) {
          try {
            writeAuditState(alertEffectiveSid, {
              audit_phase: "pending",
              audit_cause: "pre-merge-warning-flush",
              audit_armed_at: new Date().toISOString(),
              audit_retry_count: 0,
            });
          } catch (_) {}
          blockFn(formatPreMergeBlockReason("warning-flush", sessionId, alertWsid, null, null, alertEffectiveSid));
        }
      }
    }

    // Path (i-b): BLOCK verdict always gates the merge, regardless of findings (#1374).
    // Non-BLOCK verdicts (WARN, CONTINUE) skip warning-flush via isAuditVerdictFresh above.
    if (alertState) {
      const auditState = alertState.audit || {};
      const findings = (alertState.alert && Array.isArray(alertState.alert.findings) ? alertState.alert.findings : []);
      if (shouldBlockOnAuditVerdict(auditState, findings)) {
        blockFn(formatPreMergeBlockReason("audit-verdict:" + auditState.audit_verdict, sessionId, alertWsid, null, null, alertEffectiveSid));
      }
    }

    // Path (ii): scope-drift — block when branch diff contains undeclared files.
    // repoDir deferred here (not needed for Path (i)): resolveRepoDir(null, null)
    // calls parseGitCArg(null) which throws — deferring avoids the fail-open catch.
    const repoDir = hookCwd || resolveRepoDirFn(null, null);
    // Resolve wsid independently: resolveSupervisorState sets wsid only when state was
    // found via wsid fallback. When state was found via CC sessionId, wsid is null but
    // WORKFLOW_SESSION_ID env or resolveWorkflowSessionId() can still provide it.
    // Priority: wsid → WORKFLOW_SESSION_ID env (tests inject this) → WORKTREE_NOTES.md.
    const resolvedWsid = wsid || (() => {
      const env = process.env.WORKFLOW_SESSION_ID;
      if (env && /^[A-Za-z0-9_-]+$/.test(env)) return env;
      try { return resolveWorkflowSessionId(); } catch (_) { return null; }
    })();
    if (!resolvedWsid) return;
    const branchFiles = resolveBranchDiff(repoDir);
    if (!branchFiles) return;
    const plansDir = process.env.WORKFLOW_PLANS_DIR || os.homedir() + "/.workflow-plans";
    const declaredFiles = parseDetailFilesToModify(plansDir, resolvedWsid);
    if (!declaredFiles || declaredFiles.length === 0) return;

    const undeclared = branchFiles.filter(p => {
      return !declaredFiles.some(d => p === d || p.startsWith(d.endsWith("/") ? d : d + "/"));
    });

    const au = (state && state.audit) || {};
    const skipDrift = au.audit_phase === "pending" || au.audit_phase === "in_progress" ||
      (au.audit_last_run_at != null && au.audit_cause === "scope-drift:pre-merge");
    // Arm audit unconditionally on first merge (pre-merge review cycle).
    // Block only when undeclared files are present (scope drift detected).
    if (!skipDrift && branchFiles.length > 0) {
      try {
        writeAuditState(effectiveSid, {
          audit_phase: "pending",
          audit_cause: "scope-drift:pre-merge",
          audit_armed_at: new Date().toISOString(),
          audit_retry_count: 0,
        });
      } catch (_) {}
      if (undeclared.length > 0) {
        blockFn(formatPreMergeBlockReason("scope-drift:pre-merge", sessionId, resolvedWsid, null, null, effectiveSid));
      }
    }
  } catch (e) {
    // fail-open
  }
}

module.exports = {
  checkSupervisorPreMerge,
  parseDetailFilesToModify,
  shouldBlockOnAuditVerdict,
  isAuditVerdictFresh,
  resolveSupervisorState,
  resolveBranchDiff,
};
