// hooks/lib/off-clearance-invocation.js
// SSOT for the OFF-clearance invitation string (#1821). Every guard that BLOCKS
// an OFF departure must say how to get clearance, so the invitation is quoted by
// more than one emitter (dispatch.js, supervisor-off-proposal-shim.js) and by
// skills/enforce-workflow-off/SKILL.md — one owner, no stale copies (CPR-SSOT).
// The spelling is load-bearing: bin/request-off-mode-clearance is a thin wrapper
// around bin/request-off-clearance whose name does NOT contain the literal the
// mention gate keys on, so even if TOKEN_MENTION_RE's dot-adjacency narrowing
// regresses to a bare substring match, the guard still cannot block the very
// command it just told the caller to run.
"use strict";

const OFF_CLEARANCE_INVOCATION = 'bash "$AGENTS_CONFIG_DIR/bin/request-off-mode-clearance"';

module.exports = { OFF_CLEARANCE_INVOCATION };
