"use strict";
// Handles ENFORCE_WORKTREE_OFF/ON and ENFORCE_WORKFLOW_OFF/ON sentinels, which
// write or delete per-session marker files that temporarily override worktree/workflow
// enforcement. The only module that receives the signalFatal callback (hard-fail on bad session ID).

const fs = require("fs");
const path = require("path");
const { validateSkipReason } = require("./skip-reason");
const {
  ENFORCE_WORKTREE_OFF_RE_DQ, ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE,
  ENFORCE_WORKTREE_ON_RE_DQ, ENFORCE_WORKTREE_ON_LOOKSLIKE_RE,
  ENFORCE_WORKFLOW_OFF_RE_DQ, ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE,
  ENFORCE_WORKFLOW_ON_RE_DQ, ENFORCE_WORKFLOW_ON_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");
const { getWorkflowDir } = require("../lib/workflow-state");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // --- ENFORCE_WORKTREE_OFF handler ---
  const enforceOffMatch = cmd.match(ENFORCE_WORKTREE_OFF_RE_DQ);
  const enforceOffLooksLike =
    !enforceOffMatch && ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE.test(cmd);
  if (enforceOffLooksLike) {
    pushMessage(
      `workflow-mark: malformed ENFORCE_WORKTREE_OFF — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: REASON>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (enforceOffMatch) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — ENFORCE_WORKTREE_OFF sentinel NOT applied.`
      );
      return true;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — ENFORCE_WORKTREE_OFF sentinel NOT applied.`);
      return true;
    }
    let reasonStored = null;
    const rawReason = enforceOffMatch[1];
    const v = validateSkipReason(rawReason);
    if (v.ok) {
      reasonStored = v.reason;
    } else {
      // Warn but still apply — reason quality must not block emergency recovery.
      pushMessage(
        `workflow-mark: ENFORCE_WORKTREE_OFF reason rejected — ${v.msg} (override still applied)`
      );
    }
    try {
      const dir = getWorkflowDir();
      fs.mkdirSync(dir, { recursive: true });
      const markerPath = path.join(dir, `${sessionId}.worktree-off`);
      const tmp = markerPath + ".tmp";
      fs.writeFileSync(
        tmp,
        JSON.stringify({ reason: reasonStored, set_at: new Date().toISOString() }),
        { mode: 0o600 }
      );
      fs.renameSync(tmp, markerPath);
      pushMessage(
        `workflow-mark: ENFORCE_WORKTREE session override applied (marker: ${markerPath}). ` +
          `Delete the marker file to restore enforcement.`
      );
    } catch (e) {
      signalFatal(
        `workflow-mark: failed to write ENFORCE_WORKTREE override marker — ${e.message}. Override NOT applied.`
      );
    }
    return true;
  }

  // --- ENFORCE_WORKTREE_ON handler ---
  const enforceOnMatch = cmd.match(ENFORCE_WORKTREE_ON_RE_DQ);
  const enforceOnLooksLike =
    !enforceOnMatch && ENFORCE_WORKTREE_ON_LOOKSLIKE_RE.test(cmd);
  if (enforceOnLooksLike) {
    pushMessage(
      `workflow-mark: malformed ENFORCE_WORKTREE_ON — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: REASON>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (enforceOnMatch) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — ENFORCE_WORKTREE_ON sentinel NOT applied.`
      );
      return true;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — ENFORCE_WORKTREE_ON sentinel NOT applied.`);
      return true;
    }
    const rawOnReason = enforceOnMatch[1];
    const v = validateSkipReason(rawOnReason);
    if (!v.ok) {
      // Warn but still apply — reason quality must not block restoration.
      pushMessage(
        `workflow-mark: ENFORCE_WORKTREE_ON reason rejected — ${v.msg} (restore still applied)`
      );
    }
    try {
      const dir = getWorkflowDir();
      const markerPath = path.join(dir, `${sessionId}.worktree-off`);
      try {
        fs.unlinkSync(markerPath);
        pushMessage(
          `workflow-mark: ENFORCE_WORKTREE session override cleared (marker removed: ${markerPath}).`
        );
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
        // Idempotent: silent no-op when marker is already absent.
      }
    } catch (e) {
      signalFatal(
        `workflow-mark: failed to clear ENFORCE_WORKTREE override marker — ${e.message}. Restore NOT applied.`
      );
    }
    return true;
  }

  // --- ENFORCE_WORKFLOW_OFF handler ---
  const workflowOffMatch = cmd.match(ENFORCE_WORKFLOW_OFF_RE_DQ);
  const workflowOffLooksLike =
    !workflowOffMatch && ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE.test(cmd);
  if (workflowOffLooksLike) {
    pushMessage(
      `workflow-mark: malformed ENFORCE_WORKFLOW_OFF — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: REASON>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (workflowOffMatch) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — ENFORCE_WORKFLOW_OFF sentinel NOT applied.`
      );
      return true;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — ENFORCE_WORKFLOW_OFF sentinel NOT applied.`);
      return true;
    }
    let reasonStored = null;
    const rawWorkflowOffReason = workflowOffMatch[1];
    const wfv = validateSkipReason(rawWorkflowOffReason);
    if (wfv.ok) {
      reasonStored = wfv.reason;
    } else {
      pushMessage(
        `workflow-mark: ENFORCE_WORKFLOW_OFF reason rejected — ${wfv.msg} (override still applied)`
      );
    }
    try {
      const dir = getWorkflowDir();
      fs.mkdirSync(dir, { recursive: true });
      const markerPath = path.join(dir, `${sessionId}.workflow-off`);
      const tmp = markerPath + ".tmp";
      fs.writeFileSync(
        tmp,
        JSON.stringify({ reason: reasonStored, set_at: new Date().toISOString() }),
        { mode: 0o600 }
      );
      fs.renameSync(tmp, markerPath);
      pushMessage(
        `workflow-mark: ENFORCE_WORKFLOW session override applied (marker: ${markerPath}). ` +
          `Restore with: echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>"`
      );
    } catch (e) {
      signalFatal(
        `workflow-mark: failed to write ENFORCE_WORKFLOW override marker — ${e.message}. Override NOT applied.`
      );
    }
    return true;
  }

  // --- ENFORCE_WORKFLOW_ON handler ---
  const workflowOnMatch = cmd.match(ENFORCE_WORKFLOW_ON_RE_DQ);
  const workflowOnLooksLike =
    !workflowOnMatch && ENFORCE_WORKFLOW_ON_LOOKSLIKE_RE.test(cmd);
  if (workflowOnLooksLike) {
    pushMessage(
      `workflow-mark: malformed ENFORCE_WORKFLOW_ON — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: REASON>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (workflowOnMatch) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — ENFORCE_WORKFLOW_ON sentinel NOT applied.`
      );
      return true;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — ENFORCE_WORKFLOW_ON sentinel NOT applied.`);
      return true;
    }
    const rawWorkflowOnReason = workflowOnMatch[1];
    const wfOnv = validateSkipReason(rawWorkflowOnReason);
    if (!wfOnv.ok) {
      pushMessage(
        `workflow-mark: ENFORCE_WORKFLOW_ON reason rejected — ${wfOnv.msg} (restore still applied)`
      );
    }
    try {
      const dir = getWorkflowDir();
      const markerPath = path.join(dir, `${sessionId}.workflow-off`);
      try {
        fs.unlinkSync(markerPath);
        pushMessage(
          `workflow-mark: ENFORCE_WORKFLOW session override cleared (marker removed: ${markerPath}).`
        );
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
        // Idempotent: silent no-op when marker is already absent.
      }
    } catch (e) {
      signalFatal(
        `workflow-mark: failed to clear ENFORCE_WORKFLOW override marker — ${e.message}. Restore NOT applied.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
