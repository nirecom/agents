"use strict";

// Fail-open facade over appendFinding for hook/skill self-reporting.
// Every export wraps its body in try/catch and returns void on failure.

const { appendFinding } = require("./supervisor-state-writer");

function safeAppend(sessionId, finding) {
  try {
    if (!sessionId) return;
    appendFinding(sessionId, finding);
  } catch (_) {
    // swallow
  }
}

function reportBlock(hook, command, sessionId) {
  try {
    safeAppend(sessionId, {
      categories: ["workflow"],
      severity: "warning",
      detail: `hook blocked: ${hook} on ${command || "<unknown>"}`,
      reporter: hook,
    });
  } catch (_) {
    // swallow
  }
}

function reportFallback(skill, fallbackName, sessionId) {
  try {
    safeAppend(sessionId, {
      categories: ["workflow"],
      severity: "notice",
      detail: `fallback taken: ${fallbackName}`,
      reporter: skill,
    });
  } catch (_) {
    // swallow
  }
}

function reportSentinel(kind, reason, sessionId) {
  // Only report escape-hatch OPEN events (_OFF). Restore events (_ON) are safe paths.
  if (!kind || kind.endsWith("_ON")) return;
  try {
    safeAppend(sessionId, {
      categories: ["workflow"],
      severity: "warning",
      detail: `escape-hatch sentinel: ${kind} (${reason || "<no reason>"})`,
      reporter: "enforce-override-handlers",
    });
  } catch (_) {
    // swallow
  }
}

function reportRetrospective(observation, sessionId) {
  try {
    safeAppend(sessionId, {
      categories: ["other"],
      severity: "notice",
      detail: observation,
      reporter: "session-close",
    });
  } catch (_) {
    // swallow
  }
}

module.exports = { reportBlock, reportFallback, reportSentinel, reportRetrospective };
