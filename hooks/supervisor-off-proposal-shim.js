"use strict";
// PreToolUse hook: gates OFF-sentinel emit commands on a reason-bound clearance
// token (<workflowDir>/<sid>.off-clearance) minted by bin/request-off-clearance
// after a Phase1 examination (#1608).
//
// The gate is TOKEN-FIRST: it is decided before — and independently of — any
// supervisor state read. Supervisor findings/severity no longer participate in
// the verdict (deadlock root fix); the state file is consulted only to pick an
// honest block message (#1606).
//
// Fail direction: the token gate is the single fail-CLOSED point (corrupt or
// unreadable token → block). Everything else fails open (exit 0). The escape
// when the examiner itself is broken is the EMERGENCY sentinel, which is
// excluded from this gate by construction.
const fs = require("fs");
const path = require("path");

let input = "";
process.stdin.on("data", (d) => { input += d; });
process.stdin.on("end", () => {
  try {
    let resolvedWsid = null;
    let wsidResolved = false;
    const parsed = JSON.parse(input || "{}");
    const toolName = parsed.tool_name || "";
    if (toolName !== "Bash" && toolName !== "runInTerminal" && toolName !== "runCommands") process.exit(0);
    const command = (parsed.tool_input && parsed.tool_input.command) || "";

    const patterns = require(path.join(__dirname, "./lib/sentinel-patterns.js"));

    // Step 1a: exclude the EMERGENCY sentinels. Only the dedicated *_EMERGENCY_*
    // regexes match them — the normal OFF regexes below never do — so this branch
    // is what lets an emergency emit bypass the Phase1 clearance gate.
    const emergencyRes = [
      patterns.ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ,
      patterns.ENFORCE_WORKFLOW_OFF_EMERGENCY_LOOKSLIKE_RE,
      patterns.ENFORCE_WORKTREE_OFF_EMERGENCY_RE_DQ,
      patterns.ENFORCE_WORKTREE_OFF_EMERGENCY_LOOKSLIKE_RE,
    ];
    for (const re of emergencyRes) {
      if (re && re.test && re.test(command)) process.exit(0); // Phase1 bypass
    }

    // Step 1b: detect a normal OFF proposal, its target, and its reason text.
    // isGenuineEmit: true only for the strict DQ (reason-carrying) form.
    // LOOKSLIKE variants never activate a real OFF, so they pass through later.
    let isOffProposal = false;
    let isGenuineEmit = false;
    let offTarget = null;
    let reasonText = "";

    const WORKFLOW_OFF_DQ = patterns.ENFORCE_WORKFLOW_OFF_RE_DQ;
    const WORKFLOW_OFF_LOOKSLIKE = patterns.ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE;
    const WORKTREE_OFF_DQ = patterns.ENFORCE_WORKTREE_OFF_RE_DQ;
    const WORKTREE_OFF_LOOKSLIKE = patterns.ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE;

    const wfMatch = (WORKFLOW_OFF_DQ && WORKFLOW_OFF_DQ.exec) ? WORKFLOW_OFF_DQ.exec(command) : null;
    const wtMatch = (WORKTREE_OFF_DQ && WORKTREE_OFF_DQ.exec) ? WORKTREE_OFF_DQ.exec(command) : null;
    if (wfMatch) {
      isOffProposal = true; isGenuineEmit = true; offTarget = "workflow"; reasonText = wfMatch[1] || "";
    } else if (wtMatch) {
      isOffProposal = true; isGenuineEmit = true; offTarget = "worktree"; reasonText = wtMatch[1] || "";
    } else if (WORKFLOW_OFF_LOOKSLIKE && WORKFLOW_OFF_LOOKSLIKE.test && WORKFLOW_OFF_LOOKSLIKE.test(command)) {
      isOffProposal = true; offTarget = "workflow";
    } else if (WORKTREE_OFF_LOOKSLIKE && WORKTREE_OFF_LOOKSLIKE.test && WORKTREE_OFF_LOOKSLIKE.test(command)) {
      isOffProposal = true; offTarget = "worktree";
    }

    if (!isOffProposal) process.exit(0);

    const sessionId = parsed.session_id || "";

    function resolveWsid() {
      if (wsidResolved) return resolvedWsid;
      wsidResolved = true;
      try {
        const { resolveWorkflowSessionId } = require(path.join(__dirname, "./lib/resolve-workflow-session-id.js"));
        resolvedWsid = resolveWorkflowSessionId() || null;
      } catch (e) { resolvedWsid = null; }
      return resolvedWsid;
    }

    // Step 2: already OFF → nothing left to gate. Target-aware (CPR-5): WORKFLOW_OFF
    // subsumes both targets, while WORKTREE_OFF only clears a worktree-target sentinel.
    try {
      const { isWorkflowOff, isWorktreeOff } = require(path.join(__dirname, "./lib/session-markers.js"));
      if (isWorkflowOff(sessionId)) process.exit(0);
      if (offTarget === "worktree" && isWorktreeOff(sessionId)) process.exit(0);
    } catch (e) { /* fail-open */ }

    // Step 3: look-alike (non-genuine) emits never activate a real OFF.
    if (!isGenuineEmit) process.exit(0);

    // Step 4: TOKEN GATE (fail-CLOSED). The token is read directly so that
    // ENOENT stays distinguishable from other I/O and parse failures:
    //   absent → block (clearance never obtained)
    //   error  → block (corrupt/unreadable must not become a free pass)
    //   found  → validate expiry + target + reason-binding
    const SID_RE = /^[A-Za-z0-9_-]+$/;
    function readToken(sid) {
      if (!sid || !SID_RE.test(sid)) return { status: "absent" };
      let tokenPath;
      try {
        const { getWorkflowDir } = require(path.join(__dirname, "./lib/workflow-state"));
        tokenPath = path.join(getWorkflowDir(), sid + ".off-clearance");
      } catch (e) {
        return { status: "error" };
      }
      let raw;
      try {
        raw = fs.readFileSync(tokenPath, "utf8");
      } catch (readErr) {
        if (readErr && readErr.code === "ENOENT") return { status: "absent" };
        return { status: "error" };
      }
      try {
        const token = JSON.parse(raw);
        if (!token || typeof token !== "object") return { status: "error" };
        return { status: "found", token };
      } catch (e) {
        return { status: "error" };
      }
    }

    let tokenResult = readToken(sessionId);
    if (tokenResult.status === "absent") {
      const wsid = resolveWsid();
      if (wsid && wsid !== sessionId) {
        const fallback = readToken(wsid);
        if (fallback.status !== "absent") tokenResult = fallback;
      }
    }

    // Validity is decided by the shared SSOT validator (hooks/lib/session-markers.js).
    // Only the read layer above is local, so ENOENT stays distinguishable from errors.
    let allow = false;
    if (tokenResult.status === "found") {
      try {
        const { evaluateOffClearance } = require(path.join(__dirname, "./lib/session-markers.js"));
        allow = evaluateOffClearance(tokenResult.token, offTarget, reasonText) === true;
      } catch (e) {
        allow = false; // validator unavailable → fail-CLOSED
      }
    }
    if (allow) process.exit(0);

    // Step 5: the block is already decided. The supervisor state is read ONLY
    // to select an honest message (#1606) — it can no longer change the verdict.
    let stateFileFound = false;
    let stateReadFailed = false;
    try {
      const stateWriter = require(path.join(__dirname, "./lib/supervisor-state-writer.js"));
      const tryRead = (sid) => {
        if (!sid) return false;
        let raw;
        try {
          raw = fs.readFileSync(stateWriter.getStatePath(sid), "utf8");
        } catch (readErr) {
          if (readErr && readErr.code === "ENOENT") return false;
          throw readErr;
        }
        JSON.parse(raw);
        return true;
      };
      if (tryRead(sessionId)) {
        stateFileFound = true;
      } else {
        const wsid = resolveWsid();
        if (wsid && wsid !== sessionId && tryRead(wsid)) stateFileFound = true;
      }
    } catch (e) {
      stateReadFailed = true; // message falls back to the generic honest text
    }

    const blockKind = stateReadFailed
      ? "no-clearance-unknown"
      : (stateFileFound ? "no-clearance-findings" : "no-clearance-enoent");

    const CLEARANCE_GUIDANCE =
      "Request clearance with: bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> " +
      "--category <rubric category> --detail \"<why>\"\n" +
      "Then re-emit the OFF sentinel with the granted [category] inside the reason.\n" +
      "If the examiner itself is broken, use the EMERGENCY OFF sentinel.";

    function buildReason(isWtEnd, convLangPrefix, kind) {
      if (isWtEnd) {
        return convLangPrefix +
          "[EM Supervisor] OFF sentinel emit blocked.\n" +
          "This looks like the worktree-end cleanup phase. If 'git worktree remove' (WE-15) failed, WORKTREE_OFF is NOT needed — /sweep-worktrees reclaims the worktree automatically later.\n" +
          "Follow the WE-16 fallback: skip to WE-20 and continue.";
      }
      const head = convLangPrefix + "[EM Supervisor] OFF sentinel emit blocked.\n";
      if (kind === "no-clearance-enoent") {
        return head +
          "No clearance token for this session, and no supervisor examination has run yet. " +
          "Supervisor findings are NOT the reason for this block.\n" +
          CLEARANCE_GUIDANCE;
      }
      if (kind === "no-clearance-findings") {
        return head +
          "No valid clearance token for this session. Supervisor findings are NOT the reason " +
          "for this block — an OFF departure always requires a reason-bound clearance token.\n" +
          CLEARANCE_GUIDANCE;
      }
      return head +
        "No valid clearance token for this session (supervisor state could not be read; " +
        "its contents are NOT the reason for this block).\n" +
        CLEARANCE_GUIDANCE;
    }

    // Detect worktree-end cleanup context to produce an adaptive block message.
    function computeIsWtEnd() {
      let isWorktreeEndEnv;
      try {
        ({ isWorktreeEndEnv } = require(path.join(__dirname, "./lib/worktree-end-env-anchor.js")));
      } catch (e) {
        return false; // module unavailable — fall back to the fixed message
      }
      if (sessionId && isWorktreeEndEnv(sessionId)) return true;
      const wsid = resolveWsid();
      if (wsid && wsid !== sessionId && isWorktreeEndEnv(wsid)) return true;
      return false;
    }

    let convLangPrefix = "";
    try {
      const { getConvLangInjection } = require(path.join(__dirname, "./lib/conv-lang.js"));
      const injection = getConvLangInjection();
      if (injection) convLangPrefix = injection + "\n";
    } catch (e) { /* fail-open */ }

    const reason = buildReason(computeIsWtEnd(), convLangPrefix, blockKind);
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (e) {
    process.exit(0); // fail-open
  }
});
