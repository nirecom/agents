"use strict";
// bin/worker-dispatch/control-file.js — the `derived-control-file` capability type.
// The value is DERIVED from the validated session id as <workflowDir>/<sid>.control/<name>
// (docs/architecture/claude-code/state-dirs.md); a caller never chooses it.

const path = require("path");

const { realAbs, samePath, sameString } = require("./anchor");
const controlDir = require("../../hooks/workflow-state/state-io/control-dir");

const RE_SESSION_ID = /^[A-Za-z0-9_-]+$/;

function isSid(v) {
  return typeof v === "string" && RE_SESSION_ID.test(v);
}

// `field.control` is the file name; `{root}` is the payload's root_issue_number.
function controlNameFor(field, payload) {
  const tpl = field && typeof field.control === "string" ? field.control : null;
  if (tpl === null) return { error: "declares no control file name" };
  if (!tpl.includes("{root}")) return { name: tpl };
  const root = payload ? payload.root_issue_number : null;
  if (typeof root !== "number" || !Number.isInteger(root) || root < 1) {
    return { error: "cannot be derived without an integer 'root_issue_number'" };
  }
  return { name: tpl.replace("{root}", String(root)) };
}

// The payload's own session_id, else the sid carried by a control-dir payload path.
function controlSidFor(anchors, payload) {
  const own = payload ? payload.session_id : undefined;
  if (own !== undefined && own !== null) return isSid(own) ? own : null;
  const fromPath = anchors ? anchors.payloadSid : null;
  return isSid(fromPath) ? fromPath : null;
}

// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
// deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
// A pre-migration payload may still name the file: accepted only as the derived path or the
// legacy basename <sid>-<name> (which binds session and root), and never used for resolution.
function legacyValueOk(value, sid, name, derived) {
  if (typeof value !== "string" || value === "") return false;
  if (derived && samePath(value, derived)) return true;
  return sameString(path.posix.basename(value.replace(/\\/g, "/")), `${sid}-${name}`);
}
// --- END temporary: plans-dir control files -> workflow control dir migration ---

// Deriving goes through controlPath, which runs the one-time legacy migration, so a
// state file published before the pull is found at the derived path.
function checkDerivedControlFile(value, field, anchors, payload) {
  const sid = controlSidFor(anchors, payload);
  const named = controlNameFor(field, payload);
  const absent = value === undefined || value === null;
  if (sid === null || named.error) {
    if (absent) return { value: undefined };
    return { error: sid === null ? "cannot be derived without a well-formed session id" : named.error };
  }
  let derived = null;
  try {
    derived = realAbs(controlDir.controlPath(sid, named.name, { forWrite: true }));
  } catch (e) {
    return { error: `cannot be derived: ${e && e.message ? e.message : "control dir unusable"}` };
  }
  if (absent) return { value: derived };
  if (!legacyValueOk(value, sid, named.name, derived)) {
    return { error: `must be omitted (derived as <session control dir>/${named.name})` };
  }
  return { value: derived };
}

module.exports = { checkDerivedControlFile, controlNameFor, controlSidFor, legacyValueOk };
