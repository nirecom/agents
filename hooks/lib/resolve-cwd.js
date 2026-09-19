"use strict";

// Shared cwd resolution for hook payloads: prefer an explicit non-empty cwd
// value, else process.cwd(). Callers that hand the result to fs/spawn APIs wrap
// it in their own Windows path normalization (#2319). SSOT for the resolution
// rule shared by workflow-gate.js (freshnessCwd) and show-user-verified-context.js.
function resolveInputCwd(rawCwd) {
  return (typeof rawCwd === "string" && rawCwd.trim())
    ? rawCwd.trim()
    : process.cwd();
}

module.exports = { resolveInputCwd };
