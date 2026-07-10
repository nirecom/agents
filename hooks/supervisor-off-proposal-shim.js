"use strict";
// PreToolUse hook: intercepts and blocks OFF-sentinel emit commands.
// Fails open (exit 0) on any error (corrupt/missing file, I/O error).
const fs = require("fs");
const path = require("path");

let input = "";
process.stdin.on("data", (d) => { input += d; });
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(input || "{}");
    const toolName = parsed.tool_name || "";
    if (toolName !== "Bash" && toolName !== "runInTerminal" && toolName !== "runCommands") process.exit(0);
    const command = (parsed.tool_input && parsed.tool_input.command) || "";

    const patterns = require(path.join(__dirname, "./lib/sentinel-patterns.js"));

    // Check if command contains an OFF sentinel emit.
    // isGenuineEmit: true only when the DQ (double-quoted, with reason) pattern matches.
    // LOOKSLIKE patterns catch variants (no-reason, single-quoted, etc.) but are not
    // treated as genuine emits for the ENOENT-block path.
    let isOffProposal = false;
    let isGenuineEmit = false;

    const WORKFLOW_OFF_DQ = patterns.ENFORCE_WORKFLOW_OFF_RE_DQ;
    const WORKFLOW_OFF_LOOKSLIKE = patterns.ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE;
    const WORKTREE_OFF_DQ = patterns.ENFORCE_WORKTREE_OFF_RE_DQ;
    const WORKTREE_OFF_LOOKSLIKE = patterns.ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE;

    if (WORKFLOW_OFF_DQ && WORKFLOW_OFF_DQ.test && WORKFLOW_OFF_DQ.test(command)) {
      isOffProposal = true; isGenuineEmit = true;
    }
    if (!isOffProposal && WORKFLOW_OFF_LOOKSLIKE && WORKFLOW_OFF_LOOKSLIKE.test && WORKFLOW_OFF_LOOKSLIKE.test(command)) {
      isOffProposal = true;
    }
    if (!isOffProposal && WORKTREE_OFF_DQ && WORKTREE_OFF_DQ.test && WORKTREE_OFF_DQ.test(command)) {
      isOffProposal = true; isGenuineEmit = true;
    }
    if (!isOffProposal && WORKTREE_OFF_LOOKSLIKE && WORKTREE_OFF_LOOKSLIKE.test && WORKTREE_OFF_LOOKSLIKE.test(command)) {
      isOffProposal = true;
    }

    if (!isOffProposal) process.exit(0);

    const sessionId = parsed.session_id || "";

    // Check if workflow is already OFF (bypass if so)
    try {
      const { isWorkflowOff } = require(path.join(__dirname, "./lib/session-markers.js"));
      if (isWorkflowOff(sessionId)) process.exit(0);
    } catch (e) { /* fail-open */ }

    // Read state file directly to distinguish ENOENT from parse/I/O errors:
    //   - I/O error or parse error (corrupt/empty): fail-open → exit 0
    //   - ENOENT (no state file): genuine emits block; look-alikes pass through
    //   - Valid state: check L1 findings
    let state = null;
    let stateFileFound = false;
    try {
      const stateWriter = require(path.join(__dirname, "./lib/supervisor-state-writer.js"));

      const tryRead = (sid) => {
        const statePath = stateWriter.getStatePath(sid);
        let raw;
        try {
          raw = fs.readFileSync(statePath, "utf8");
        } catch (readErr) {
          if (readErr.code === "ENOENT") return null; // file not found
          throw readErr; // other I/O error → fail-open via outer catch
        }
        // Parse error (corrupt/empty) → fail-open via outer catch
        return { parsed: JSON.parse(raw) };
      };

      let primary = null;
      if (sessionId) primary = tryRead(sessionId);
      if (primary === null) {
        // ENOENT for primary — try wsid fallback
        try {
          const { resolveWorkflowSessionId } = require(path.join(__dirname, "./lib/resolve-workflow-session-id.js"));
          const wsid = resolveWorkflowSessionId();
          if (wsid) {
            const fallback = tryRead(wsid);
            if (fallback !== null) { stateFileFound = true; state = fallback.parsed; }
          }
        } catch (_) { /* wsid resolution failed — stateFileFound stays false */ }
      } else {
        stateFileFound = true;
        state = primary.parsed;
      }
    } catch (e) {
      // I/O error or parse error (corrupt/empty file) — fail-open
      process.exit(0);
    }

    // No state file found (ENOENT) — block genuine emits, pass look-alikes
    if (!stateFileFound) {
      if (!isGenuineEmit) process.exit(0); // look-alike without state → pass
      // Genuine emit + no state file → block (no supervisor clearance established)
      let convLangPrefix = "";
      try {
        const { getConvLangInjection } = require(path.join(__dirname, "./lib/conv-lang.js"));
        const injection = getConvLangInjection();
        if (injection) convLangPrefix = injection + "\n";
      } catch (e) { /* fail-open */ }
      const reason = convLangPrefix +
        "[EM Supervisor] OFF sentinel emit blocked.\n" +
        "Active supervisor findings exist.\n" +
        "Re-run after the supervisor audit completes.";
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
      process.exit(2);
    }

    // State file found — check L1 findings (non-notice severity)
    const l1Findings = (state && state.layer1 && Array.isArray(state.layer1.findings)) ? state.layer1.findings : [];
    const blockingFindings = l1Findings.filter(f => f && f.severity !== "notice");

    // Pass through if no blocking findings
    if (blockingFindings.length === 0) process.exit(0);

    // Pass through if all blocking findings are from enforce-worktree (false-block recovery)
    if (blockingFindings.every(f => f.reporter === "enforce-worktree")) process.exit(0);

    // Block: compute CONV_LANG prefix
    let convLangPrefix = "";
    try {
      const { getConvLangInjection } = require(path.join(__dirname, "./lib/conv-lang.js"));
      const injection = getConvLangInjection();
      if (injection) convLangPrefix = injection + "\n";
    } catch (e) { /* fail-open */ }

    const reason = convLangPrefix +
      "[EM Supervisor] OFF sentinel emit blocked.\n" +
      "Active supervisor findings exist.\n" +
      "Re-run after the supervisor audit completes.";

    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (e) {
    process.exit(0); // fail-open
  }
});
