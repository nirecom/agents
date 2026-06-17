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

// extras schema (Axis A, #885):
//   reason?: string (>=1 char)
//   context?: { cwd?: string, git_root_resolved?: boolean }  — other keys dropped
//   co_blocked_by?: string[]  — non-string elements dropped, empty array omitted
// Invalid types (non-plain-object extras) silently ignored (fail-open).
function reportBlock(hook, command, sessionId, extras = {}) {
  try {
    const finding = {
      categories: ["workflow"],
      severity: "warning",
      detail: `hook blocked: ${hook} on ${command || "<unknown>"}`,
      reporter: hook,
    };
    if (extras && typeof extras === "object" && !Array.isArray(extras)) {
      if (typeof extras.reason === "string" && extras.reason.length >= 1) {
        finding.reason = extras.reason;
      }
      if (extras.context && typeof extras.context === "object" && !Array.isArray(extras.context)) {
        const ctx = {};
        if (typeof extras.context.cwd === "string") ctx.cwd = extras.context.cwd;
        if (typeof extras.context.git_root_resolved === "boolean") {
          ctx.git_root_resolved = extras.context.git_root_resolved;
        }
        if (Object.keys(ctx).length > 0) finding.context = ctx;
      }
      if (Array.isArray(extras.co_blocked_by)) {
        const cbb = extras.co_blocked_by.filter((r) => typeof r === "string" && r.length >= 1);
        if (cbb.length > 0) finding.co_blocked_by = cbb;
      }
    }
    safeAppend(sessionId, finding);
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
