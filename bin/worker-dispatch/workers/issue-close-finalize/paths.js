"use strict";
// bin/worker-dispatch/workers/issue-close-finalize/paths.js — where the finalize chain's
// control files live: <workflowDir>/<sid>.control/ (docs/architecture/claude-code/state-dirs.md).
// The state and outcome paths arrive derived by capability.js; this module owns the binding record.

const path = require("path");

const { controlPath } = require("../../../../hooks/workflow-state/state-io/control-dir");
const { samePath, sameString } = require("../../anchor");

function bindingPath(sessionId, rootIssueNumber, opts) {
  return controlPath(sessionId, `finalize-binding-${rootIssueNumber}.json`, opts);
}

// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
// deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
// A binding migrated from PLANS_DIR still records the legacy state path <sid>-finalize-state-<root>.json.
function isLegacyStatePath(recorded, sessionId, rootIssueNumber) {
  if (typeof recorded !== "string" || recorded === "") return false;
  const base = path.posix.basename(recorded.replace(/\\/g, "/"));
  return sameString(base, `${sessionId}-finalize-state-${rootIssueNumber}.json`);
}
// --- END temporary: plans-dir control files -> workflow control dir migration ---

function bindingStateMatches(recorded, statePath, sessionId, rootIssueNumber) {
  if (samePath(recorded, statePath)) return true;
  return isLegacyStatePath(recorded, sessionId, rootIssueNumber);
}

module.exports = { bindingPath, bindingStateMatches };
