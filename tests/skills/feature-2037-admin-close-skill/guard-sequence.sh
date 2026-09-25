# shellcheck shell=bash
# Tests: skills/issue-close-verified/SKILL.md, hooks/enforce-issue-close.js, hooks/workflow-mark/enforce-override-handlers.js
# Tags: rules-injection, admin-close, issue-close-verified, sentinel, guard-sequence, executable-doc, TL2, scope:issue-specific

# WHY this is separate from S1-S8 (CPR-WPH): every case there stops at the MARKER — the
# skill's opening command creates a file, its closing command removes it. That is one half
# of the contract. The half a user actually feels is the GUARD: whether `gh issue close`
# is refused before the window opens, permitted while it is open, and refused again once
# it closes. A handler that wrote the marker to the wrong name, or a guard that stopped
# consulting it, would leave S2 green and the skill useless (or, worse, permanently
# permissive) — the marker would appear and disappear on schedule while the guard ignored
# it throughout.

# The sequence below is driven by the skill's OWN extracted sentinel commands (ICV_ON_CMD /
# ICV_END_CMD from the entry file), through the real handler module, against the real
# PreToolUse hook. Nothing is reconstructed: what a reader is told to type is what runs.
# Pattern follows tests/feature-1077-issue-close-verified.sh (blocked=exit 2, allowed=exit 0).

# Assumes AGENTS_DIR, _AGENTS_DIR_NODE, TMPDIR_BASE, HANDLERS_JS, ICV_ON_CMD, ICV_END_CMD,
# WORKFLOW_PLANS_DIR, fresh_workflow_dir(), run_with_timeout(), pass(), fail() from the entry file.

echo ""
echo "=== S9: end-to-end — gh issue close is blocked, then allowed inside the window, then blocked again ==="

S9_HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-issue-close.js"

# s9_close_rc <sid> <wfdir> -> prints the hook's exit code for a bare `gh issue close`.
s9_close_rc() {
    local sid="$1" wfdir="$2" rc=0 payload
    payload="$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:"Bash",tool_input:{command:"gh issue close "+process.argv[2]}}))' "$sid" 4242)"
    printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u ISSUE_CLOSE_SKILL \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node "$S9_HOOK" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# s9_emit <sid> <wfdir> <command> -> feeds one sentinel command to the real handler.
s9_emit() {
    local sid="$1" wfdir="$2" cmd="$3"
    run_with_timeout 30 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node -e '
"use strict";
const handlers = require(process.argv[1]);
handlers.handle({
  cmd: process.argv[4],
  sessionId: process.argv[2],
  pushMessage: () => {},
  signalFatal: () => {},
});
' "$HANDLERS_JS" "$sid" "$wfdir" "$cmd" >/dev/null 2>&1 || true
}

if [ ! -f "$AGENTS_DIR/hooks/enforce-issue-close.js" ]; then
    fail "S9: IMPLEMENTATION MISSING: hooks/enforce-issue-close.js — the guard this skill exists to open a window in"
elif [ -z "${ICV_ON_CMD:-}" ] || [ -z "${ICV_END_CMD:-}" ]; then
    fail "S9: the skill's sentinel commands could not be extracted (see S2), so the sequence cannot be driven from the document"
else
    S9_WF="$(fresh_workflow_dir)"
    S9_SID="s9sid2037"

    S9_BEFORE="$(s9_close_rc "$S9_SID" "$S9_WF")"
    if [ "$S9_BEFORE" = "2" ]; then
        pass "S9a: before the skill runs, a bare gh issue close is blocked (exit 2)"
    else
        fail "S9a: want exit 2 with no marker, got rc=$S9_BEFORE — the guard is already open, so S9b would prove nothing about the skill"
    fi

    s9_emit "$S9_SID" "$S9_WF" "$ICV_ON_CMD"
    S9_INSIDE="$(s9_close_rc "$S9_SID" "$S9_WF")"
    if [ "$S9_INSIDE" = "0" ]; then
        pass "S9b: after the skill's OPENING command, the same close is permitted (exit 0) — the marker the skill writes is the one the guard reads"
    else
        fail "S9b: want exit 0 inside the window, got rc=$S9_INSIDE — the skill creates a marker the guard does not honour, so following it cannot actually close an issue"
    fi

    s9_emit "$S9_SID" "$S9_WF" "$ICV_END_CMD"
    S9_AFTER="$(s9_close_rc "$S9_SID" "$S9_WF")"
    if [ "$S9_AFTER" = "2" ]; then
        pass "S9c: after the skill's CLOSING command, the close is blocked again (exit 2) — the window does not outlive the skill"
    else
        fail "S9c: want exit 2 after the END sentinel, got rc=$S9_AFTER — the bypass survives the skill and every later close in the session runs unguarded"
    fi

    # Scope: the window is keyed to the session that opened it. Without this, a marker
    # written under a shared or fixed name would satisfy S9b for every concurrent session
    # at once, and S9a/S9c would still pass.
    s9_emit "$S9_SID" "$S9_WF" "$ICV_ON_CMD"
    S9_OTHER="$(s9_close_rc "othersid2037" "$S9_WF")"
    if [ "$S9_OTHER" = "2" ]; then
        pass "S9d: with the window open for one session, a DIFFERENT session is still blocked (exit 2)"
    else
        fail "S9d: a second session got rc=$S9_OTHER while the window belonged to $S9_SID — the bypass is not session-scoped, so one admin close disarms the guard for every concurrent session"
    fi
    s9_emit "$S9_SID" "$S9_WF" "$ICV_END_CMD"
fi

# S9e/S9f depend on the guard alone, never on the skill document, so they sit outside the
# sentinel-extraction branch above — a missing skill must not take the always-allowed
# controls down with it.
if [ ! -f "$AGENTS_DIR/hooks/enforce-issue-close.js" ]; then
    fail "S9e/S9f: IMPLEMENTATION MISSING: hooks/enforce-issue-close.js"
else
    # The guard has two other doors, and neither belongs to this skill. A hook
    # rewritten to key everything on the new marker would pass S9a-S9d while quietly
    # sealing them — the standard /issue-close-finalize path stops working, and every
    # unrelated Bash command starts needing a bypass. Both are checked with NO marker
    # present, so only the guard's own always-allowed paths can produce a 0.
    S9_CLEAN_WF="$(fresh_workflow_dir)"
    S9_SKILL_RC=0
    printf '%s' "$(node -e 'process.stdout.write(JSON.stringify({session_id:"s9esid2037",tool_name:"Bash",tool_input:{command:"gh issue close 4242"}}))')" \
        | run_with_timeout 30 env -u CLAUDE_ENV_FILE \
            "ISSUE_CLOSE_SKILL=1" \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$S9_CLEAN_WF" \
            "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
            node "$S9_HOOK" >/dev/null 2>&1 || S9_SKILL_RC=$?
    if [ "$S9_SKILL_RC" = "0" ]; then
        pass "S9e: the standard finalize path (ISSUE_CLOSE_SKILL=1, no marker) is still allowed"
    else
        fail "S9e: the skill-internal close path got rc=$S9_SKILL_RC with no marker — /issue-close-finalize now needs the admin bypass, so the workflow-managed close is broken by the escape hatch that was only meant to sit beside it"
    fi

    S9_UNREL_RC=0
    printf '%s' "$(node -e 'process.stdout.write(JSON.stringify({session_id:"s9fsid2037",tool_name:"Bash",tool_input:{command:"gh issue list --state open"}}))')" \
        | run_with_timeout 30 env -u CLAUDE_ENV_FILE -u ISSUE_CLOSE_SKILL \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$S9_CLEAN_WF" \
            "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
            node "$S9_HOOK" >/dev/null 2>&1 || S9_UNREL_RC=$?
    if [ "$S9_UNREL_RC" = "0" ]; then
        pass "S9f: an unrelated gh command is still allowed with no marker — the guard did not widen to every gh call"
    else
        fail "S9f: 'gh issue list' got rc=$S9_UNREL_RC — the guard now blocks commands that close nothing, so ordinary read-only work is stuck behind an admin escape hatch"
    fi
fi
