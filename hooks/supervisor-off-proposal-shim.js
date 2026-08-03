"use strict";
// PreToolUse hook: gates OFF-sentinel emit commands on a reason-bound clearance
// token (<workflowDir>/<sid>.off-clearance) minted by bin/request-off-clearance.
// Token-first: decided before, and independent of, any supervisor state read —
// the state file only picks an honest block message, never the verdict. Only the
// token check fails CLOSED; everything else fails open. EMERGENCY sentinels
// bypass this gate by construction (for when the examiner itself is broken).
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
    // runCommands carries an ARRAY under `commands`, not `.command` — normalization
    // shared with enforce-system-ops.js / block-off-clearance-write (CPR-2).
    const { isCommandTool, commandTextOf, commandListOf } = require(path.join(__dirname, "./lib/tool-command-text.js"));
    if (!isCommandTool(toolName)) process.exit(0);

    const patterns = require(path.join(__dirname, "./lib/sentinel-patterns.js"));

    // convLangPrefix(): conversation-language injection for any block message.
    // Shared by the multi-sentinel block below and the Step-5 block tail (CPR-2).
    function convLangPrefix() {
      try {
        const { getConvLangInjection } = require(path.join(__dirname, "./lib/conv-lang.js"));
        const injection = getConvLangInjection();
        return injection ? injection + "\n" : "";
      } catch (e) {
        return ""; // fail-open: the message is emitted without the prefix
      }
    }
    function emitBlock(body) {
      process.stdout.write(JSON.stringify({ decision: "block", reason: convLangPrefix() + body }) + "\n");
      process.exit(2);
    }

    // --- Adjudication units ------------------------------------------------
    // One tool call can carry many commands (runCommands' `commands` array, or
    // `a && b` in Bash/runInTerminal, which workflow-mark.js also splits on `&&`).
    // Adjudicating only the first OFF-looking element let a call with two sentinels
    // get validated/claimed once while activating both. So expand into the same
    // units the activation layer sees, and judge each independently.
    const AND_SPLIT_RE = /\s*&&\s*/;
    const matchesAny = (res, text) => res.some((re) => re && re.test && re.test(text));
    const units = [];
    for (const element of commandListOf(toolName, parsed.tool_input)) {
      for (const part of String(element).split(AND_SPLIT_RE)) {
        const unit = part.trim();
        if (unit) units.push(unit);
      }
    }

    // ACTIVATING units are the strict (reason-carrying) forms only — the four that
    // really turn an OFF on. LOOKSLIKE forms activate nothing (workflow-mark rejects
    // them as malformed), so they are deliberately NOT counted here: counting them
    // would block inert text.
    const ACTIVATING_OFF_RES = [
      patterns.ENFORCE_WORKFLOW_OFF_RE_DQ,
      patterns.ENFORCE_WORKTREE_OFF_RE_DQ,
      patterns.ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ,
      patterns.ENFORCE_WORKTREE_OFF_EMERGENCY_RE_DQ,
    ];
    const activatingUnits = units.filter((u) => matchesAny(ACTIVATING_OFF_RES, u));

    // One clearance authorizes exactly ONE activation (CPR-8): reject outright rather
    // than gate N times, since N sentinels can't be bound/consumed in an order this
    // gate can observe. Also blocks smuggling a gated sentinel past Phase1 by pairing
    // it with an EMERGENCY one in the same call.
    if (activatingUnits.length > 1) {
      emitBlock(
        "[EM Supervisor] OFF sentinel emit blocked.\n" +
        `This call carries ${activatingUnits.length} OFF sentinels; a clearance authorizes exactly ONE ` +
        "activation, so multi-sentinel OFF calls are rejected outright.\n" +
        "Emit ONE OFF sentinel per tool call (WORKFLOW_OFF already subsumes WORKTREE_OFF — " +
        "emitting both is redundant)."
      );
    }

    // Exactly one activating unit → adjudicate that unit. None → fall back to the
    // first LOOKSLIKE unit so the malformed-form pass-through below still works,
    // and to the whole command text when there is no list at all.
    const NORMAL_OFF_LOOKSLIKE_RES = [
      patterns.ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE,
      patterns.ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE,
    ];
    const command =
      activatingUnits[0] ||
      units.find((u) => matchesAny(NORMAL_OFF_LOOKSLIKE_RES, u)) ||
      commandTextOf(toolName, parsed.tool_input);

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
        const { getWorkflowDir } = require(path.join(__dirname, "./workflow-state"));
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
        return { status: "found", token, tokenPath, sid };
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

    // #1626: the bare token may be legitimately absent because an earlier proposal
    // already claimed and consumed it. Distinguish that case (honest "already
    // claimed" message) from "never granted" by checking for the .claimed marker
    // before falling through to the generic no-clearance message. Read-only and
    // reachable only when the verdict is already block — it never changes the verdict.
    let claimFailedBecauseClaimed = false;
    let unlinkFailedAfterClaim = false;
    if (tokenResult.status !== "found") {
      const candidateSids = [sessionId];
      const wsidForClaimedCheck = resolveWsid();
      if (wsidForClaimedCheck && wsidForClaimedCheck !== sessionId) candidateSids.push(wsidForClaimedCheck);
      try {
        const { getWorkflowDir } = require(path.join(__dirname, "./workflow-state"));
        const dir = getWorkflowDir();
        for (const sid of candidateSids) {
          if (sid && SID_RE.test(sid) && fs.existsSync(path.join(dir, sid + ".off-clearance.claimed"))) {
            claimFailedBecauseClaimed = true;
            break;
          }
        }
      } catch (e) { /* fail-open: diagnostic-only, verdict unaffected */ }
    }

    // The validate-then-claim-then-unlink sequence below mutates the same bare-token/
    // claim pair the mint transition mutates, so it takes the SAME SID-scoped lock
    // (off-clearance-mint-lock.js) — otherwise a racing mint could overwrite the token
    // this process is about to unlink, or sweep the `.claimed` file mid-creation as
    // stale. Only this mutating section needs the lock; the fast-path reads above
    // don't touch shared state.
    let validated = false;
    let allow = false;
    let lockUnavailable = false;
    if (tokenResult.status === "found") {
      const { acquireMintLock, releaseMintLock } = require(path.join(__dirname, "./lib/off-clearance-mint-lock.js"));
      // Shorter budget than the mint's 5s: this runs inline in an interactive hook
      // and must not stall the session. Timeout fails CLOSED like every other branch.
      const lock = acquireMintLock(tokenResult.tokenPath, 1000, 20);
      if (!lock) {
        lockUnavailable = true;
      } else {
        try {
          // Re-read INSIDE the lock rather than trusting the pre-lock read — a
          // concurrent mint could have overwritten it in between.
          let freshRaw = null;
          try {
            freshRaw = fs.readFileSync(tokenResult.tokenPath, "utf8");
          } catch (e) {
            freshRaw = null; // ENOENT or other I/O error → treat as not found
          }
          let freshToken = null;
          if (freshRaw !== null) {
            try { freshToken = JSON.parse(freshRaw); } catch (e) { freshToken = null; }
          }

          // Validity is decided by the shared SSOT validator
          // (hooks/lib/session-markers.js); it is a PRECONDITION only.
          if (freshToken && typeof freshToken === "object") {
            try {
              const { evaluateOffClearance } = require(path.join(__dirname, "./lib/session-markers.js"));
              validated = evaluateOffClearance(freshToken, offTarget, reasonText) === true;
            } catch (e) {
              validated = false; // validator unavailable → fail-CLOSED
            }
          }

          // The CLAIM is the authorization: exclusive-create of .claimed is one
          // indivisible op, so at most one of N concurrent proposals can obtain it —
          // closing the validate/consume TOCTOU window. No fallback on failure (block).
          // `wx` not rename: rename's exists-destination behavior differs POSIX vs
          // Windows; `wx` throws EEXIST on both (CPR-8).
          if (validated) {
            const bare = tokenResult.tokenPath;
            const claimed = bare + ".claimed";
            // Serialized before the exclusive open so a racing reader only ever
            // observes absent or fully-formed, never a transient partial file.
            const claimPayload = JSON.stringify({
              ...freshToken,
              claimed_at: new Date().toISOString(),
              claimed_by_sid: tokenResult.sid,
              claimed_target: offTarget,
              claimed_reason: reasonText,
            });
            let fd = null;
            try {
              fd = fs.openSync(claimed, "wx", 0o600);
              fs.writeFileSync(fd, claimPayload);
              allow = true;
            } catch (e) {
              if (e && e.code === "EEXIST") claimFailedBecauseClaimed = true;
              allow = false;                                  // fail-CLOSED, no fallback
            } finally {
              if (fd !== null) { try { fs.closeSync(fd); } catch (_e) {} }
            }
            // Removing the bare token is not bookkeeping: consumeOffClearance() deletes
            // .claimed on activation, so a surviving unclaimed bare token could be
            // claimed a second time afterward — a replay. Fail closed on unlink failure.
            if (allow) {
              try {
                fs.unlinkSync(bare);
              } catch (e) {
                if (!e || e.code !== "ENOENT") { allow = false; unlinkFailedAfterClaim = true; }
              }
            }
          }
        } finally {
          releaseMintLock(lock);
        }
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

    // The already-claimed state is used ONLY to pick an honest message. It never
    // participates in the verdict — the verdict was decided by the claim attempt
    // above, and no read of the .claimed file can grant permission.
    const blockKind = unlinkFailedAfterClaim
      ? "consume-failed"
      : (claimFailedBecauseClaimed
        ? "already-claimed"
        : (lockUnavailable
          ? "lock-busy"
          : (stateReadFailed
            ? "no-clearance-unknown"
            : (stateFileFound ? "no-clearance-findings" : "no-clearance-enoent"))));

    const CLEARANCE_GUIDANCE =
      "Request clearance with: bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> " +
      "--category <rubric category> --detail \"<why>\"\n" +
      "Then re-emit the OFF sentinel with the granted [category] at the START of the reason.\n" +
      "If the examiner itself is broken, use the EMERGENCY OFF sentinel.";

    function buildReason(isWtEnd, langPrefix, kind) {
      if (isWtEnd) {
        return langPrefix +
          "[EM Supervisor] OFF sentinel emit blocked.\n" +
          "This looks like the worktree-end cleanup phase. If 'git worktree remove' (WE-15) failed, WORKTREE_OFF is NOT needed — /sweep-worktrees reclaims the worktree automatically later.\n" +
          "Follow the WE-16 fallback: skip to WE-20 and continue.";
      }
      const head = langPrefix + "[EM Supervisor] OFF sentinel emit blocked.\n";
      if (kind === "consume-failed") {
        return head +
          "This session's clearance token was found and claimed, but could not be fully consumed " +
          "(the bare token file could not be removed) — it is left wedged as single-use-spent for safety. " +
          "Request a new clearance.\n" +
          CLEARANCE_GUIDANCE;
      }
      if (kind === "already-claimed") {
        return head +
          "This session's clearance token was already claimed by an earlier OFF proposal (single-use). " +
          "Request a new clearance.\n" +
          CLEARANCE_GUIDANCE;
      }
      if (kind === "lock-busy") {
        return head +
          "A clearance mint/claim for this session is in progress (mint lock busy). This is transient — " +
          "re-emit the same OFF sentinel; the concurrent operation should have released the lock within " +
          "a second or two.";
      }
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

    const reason = buildReason(computeIsWtEnd(), convLangPrefix(), blockKind);
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (e) {
    process.exit(0); // fail-open
  }
});
