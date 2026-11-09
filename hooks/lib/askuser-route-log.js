"use strict";
// askuser-route-log.js — one record per AskUserQuestion the PreToolUse hook identified (#2764):
// which route decided whether Jev answered it. One shared file, askuser-routes.jsonl under
// resolveLogDir(); a call without a session id is recorded with session_id null. Best effort.
// Only a well-formed dialog ID is kept: any other model-supplied text becomes "(malformed)".

const path = require("path");
const { appendJsonlRotating, resolveLogDir } = require("./jsonl-rotating-log");
const { DIALOG_ID_RE } = require("./askuser-dialog-levels");

const FILE_NAME = "askuser-routes.jsonl";
const ROUTES = Object.freeze([
  "invalid-input", "jev-off", "flag-off", "no-id", "malformed-id", "unclassified", "high", "no-sid",
  "no-state", "no-step", "step-mismatch", "approval-wait", "adapter-reject", "multiselect",
  "answered", "jev-declined", "error",
]);

function routeLogPath() {
  return path.join(resolveLogDir(), FILE_NAME);
}

function safeDialogId(id) {
  if (id === null || id === undefined) return null;
  return typeof id === "string" && DIALOG_ID_RE.test(id) ? id : "(malformed)";
}

// recordRoute({sessionId, dialogId, route, step, jevCalled}) — never throws.
function recordRoute(r = {}) {
  try {
    appendJsonlRotating(routeLogPath(), {
      version: 1,
      ts: new Date().toISOString(),
      session_id: typeof r.sessionId === "string" ? r.sessionId : null,
      dialog_id: safeDialogId(r.dialogId),
      route: ROUTES.includes(r.route) ? r.route : "error",
      step: typeof r.step === "string" ? r.step : null,
      jev_called: r.jevCalled === true,
    });
  } catch (_e) { /* best effort: the dialog still reaches its route */ }
}

module.exports = { ROUTES, FILE_NAME, routeLogPath, recordRoute };
