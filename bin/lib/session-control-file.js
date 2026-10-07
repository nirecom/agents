"use strict";
// bin/lib/session-control-file.js — resolves a session-close control file from --session as
// <WORKFLOW_STATE_DIR>/<sid>.control/<name> through the one control-dir resolver.
// Shared by session-close-build-env.js, render-final-report.js and session-close-render-sc7.js.
const path = require("path");

const CD = require("../../hooks/workflow-state/state-io/control-dir");

// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
// deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
const { legacyValueOk } = require("../worker-dispatch/control-file");

// A legacy path argument names its session either as <sid>-<name> or as <sid>.control/<name>.
function sidFromLegacy(value, name) {
  if (typeof value !== "string" || value === "") return null;
  const norm = value.replace(/\\/g, "/");
  const base = path.posix.basename(norm);
  const suffix = `-${name}`;
  if (base.length > suffix.length && base.endsWith(suffix)) return base.slice(0, -suffix.length);
  const parent = path.posix.basename(path.posix.dirname(norm));
  if (base === name && parent.endsWith(".control")) return parent.slice(0, -".control".length);
  return null;
}

function checkLegacy(legacy, sid, name) {
  const derived = path.join(CD.getSessionControlDir(sid), name);
  if (!legacyValueOk(legacy, sid, name, derived)) {
    throw new Error(`legacy path ${JSON.stringify(legacy)} is neither <session control dir>/${name} nor <sid>-${name} of session ${sid}`);
  }
}
// --- END temporary: plans-dir control files -> workflow control dir migration ---

// Validation (sid, legacy argument) completes before anything is created on disk.
function resolveControlFile({ sid, legacy, name, forWrite }) {
  let effectiveSid = sid;
  if (effectiveSid === undefined) effectiveSid = sidFromLegacy(legacy, name);
  if (effectiveSid === null || effectiveSid === undefined) {
    throw new Error(`cannot derive the session for ${name}: pass --session <sid>`);
  }
  CD.assertValidControlSid(effectiveSid);
  if (legacy !== undefined) checkLegacy(legacy, effectiveSid, name);
  return CD.controlPath(effectiveSid, name, { forWrite: !!forWrite });
}

module.exports = { resolveControlFile };
