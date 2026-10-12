#!/usr/bin/env node
"use strict";
// PostToolUse / PostToolUseFailure (Bash) hook: repair a Windows-form PATH line in this
// session's shell snapshots so the next Bash call stops exiting 127 (#2221). It reports what
// it did through additionalContext and never re-runs the failed command. Always exits 0.
// When to scan and the per-session marker: postuse-shell-snapshot-repair/session-check.js.

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { decide, runCheck } = require("./postuse-shell-snapshot-repair/session-check");

// Must equal the settings.json timeout (seconds) x 1000 for both registrations.
const HOOK_TIMEOUT_MS = 5000;

function main() {
  const r = readHookInput();
  if (r.kind !== "ok" || !r.input || typeof r.input !== "object") {
    const msg = readFailOpenDiagnostic("postuse-shell-snapshot-repair", r.kind === "ok" ? { kind: "json-invalid", text: r.text, error: new Error("not an object") } : r);
    try { process.stderr.write(msg + "\n"); } catch (_) { /* ignore */ }
    return;
  }
  const input = r.input;
  const decision = decide(input, { now: Date.now() });
  if (decision.action !== "first" && decision.action !== "recheck") return;
  const text = runCheck(input, decision, { hookTimeoutMs: HOOK_TIMEOUT_MS, now: Date.now() });
  if (!text) return;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: decision.event, additionalContext: text } }) + "\n");
}

try { main(); } catch (_) { /* fail-open */ }
process.exitCode = 0;
