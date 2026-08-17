# shellcheck shell=bash
# Tests: skills/enforce-workflow-off/SKILL.md, hooks/workflow-mark/enforce-override-handlers.js, hooks/enforce-worktree.js
# Tags: rules-injection, minimized-unconditional, escape-hatch, workflow-off, worktree-off, sentinel, executable-doc, TL2, scope:issue-specific

# WHY this is separate from E1-E9 (CPR-WPH): every case there grades the escape-hatch
# skill as TEXT — the sentinel spellings survived the move, they appear in
# suspend-then-restore order, the prose still calls the restore obligatory. All of that is
# satisfied by a page that documents a command which no longer works.

# The admin-close half of #2037 is already graded end to end (S9 drives the extracted
# commands through the real handler and the real guard). CPR-ORTH: the OFF/ON hatches are
# the symmetric members of that class and get the same treatment, because the failure they
# hide is worse — a documented OFF that writes nothing leaves a blocked session with a
# command that appears to work and changes nothing, in the one situation where the session
# is least able to diagnose it.

# So: extract the skill's OWN commands, run them through the real handler, and assert the
# per-session marker appears, disappears, stays isolated from another session, and
# tolerates a repeated restore. Nothing is reconstructed.

# Assumes AGENTS_DIR, BASE, EWO_ABS, pass(), fail(), node_path() from the entry file.

echo ""
echo "=== E10: the relocated OFF/ON commands, driven through the real handler ==="

E10_HANDLERS="$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers.js"

E10_run_with_timeout() {
    local secs="$1"; shift
    if [ -x "$AGENTS_DIR/bin/run-with-timeout.sh" ]; then
        "$AGENTS_DIR/bin/run-with-timeout.sh" "$secs" "$@"
    else
        "$@"
    fi
}

# Fixture isolation (rules/test/fixture-isolation.md): both halves of the pair are pinned.
# Pinning CLAUDE_WORKFLOW_DIR alone lets the supervisor emitter resolve the developer's
# real ~/.workflow-plans and append there.
E10_WF="$BASE/e10-wf"
E10_PLANS="$BASE/e10-plans"
mkdir -p "$E10_WF" "$E10_PLANS"

# e10_emit <sid> <command> — feeds one sentinel command to the real handler module and
# prints what the handler SIGNALLED, one line per callback ("FATAL: ..." / "MSG: ...").
# Swallowing those with no-op callbacks is its own false green: a restore that fails
# loudly and leaves no marker behind is indistinguishable, filesystem-side, from a
# restore that succeeded — and the reader is told to run it unconditionally.
e10_emit() {
    local sid="$1" cmd="$2"
    E10_run_with_timeout 30 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$(node_path "$E10_WF")" \
        "WORKFLOW_PLANS_DIR=$(node_path "$E10_PLANS")" \
        node -e '
"use strict";
const handlers = require(process.argv[1]);
try {
  handlers.handle({
    cmd: process.argv[3],
    sessionId: process.argv[2],
    pushMessage: (m) => console.log("MSG: " + String(m).replace(/\s+/g, " ")),
    signalFatal: (m) => console.log("FATAL: " + String(m).replace(/\s+/g, " ")),
  });
} catch (e) {
  console.log("FATAL: threw " + String(e && e.message).replace(/\s+/g, " "));
}
' "$(node_path "$E10_HANDLERS")" "$sid" "$cmd" 2>&1 || echo "FATAL: handler process exited nonzero"
}

# e10_markers <sid> — prints the marker basenames that exist for that session, sorted.
e10_markers() {
    find "$E10_WF" -maxdepth 1 -name "$1.*" -type f 2>/dev/null \
        | sed 's|.*/||' | sed "s|^$1\.||" | sort | tr '\n' ' '
}

# e10_cmd <sentinel-token> — the skill's own echo line for that sentinel, verbatim.
# A page that only NAMES the token (E4/E8 already accept that) yields nothing here, and
# the case reports the document as unrunnable rather than silently grading a command the
# test wrote for itself.
e10_cmd() {
    grep -oE "echo \"<<$1: [^\"]*>>\"" "$EWO_ABS" 2>/dev/null | head -1
}

if [ ! -f "$E10_HANDLERS" ]; then
    fail "E10: IMPLEMENTATION MISSING: hooks/workflow-mark/enforce-override-handlers.js — the module every OFF/ON sentinel is routed through"
elif [ ! -f "$EWO_ABS" ]; then
    fail "E10: the enforce-workflow-off skill does not exist, so there is no relocated command to run"
else
    # Which OFF form the skill actually SHOWS is a decision made elsewhere: #1780 forbids
    # this skill from instructing the clearance-gated standard spelling, so its runnable OFF
    # command is the _EMERGENCY variant. Both sentinels write the same ${sid}.workflow-off
    # marker, so the sequence below is equally valid driven by either — but the preference
    # order is fixed (standard first, _EMERGENCY only as fallback) so that a skill showing
    # both never silently changes which form these cases grade.
    E10_OFF="$(e10_cmd WORKFLOW_ENFORCE_WORKFLOW_OFF)"
    E10_OFF_FORM="standard"
    if [ -z "$E10_OFF" ]; then
        E10_OFF="$(e10_cmd WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY)"
        E10_OFF_FORM="_EMERGENCY"
    fi
    E10_ON="$(e10_cmd WORKFLOW_ENFORCE_WORKFLOW_ON)"
    E10_WT_OFF="$(e10_cmd WORKFLOW_ENFORCE_WORKTREE_OFF)"
    E10_WT_ON="$(e10_cmd WORKFLOW_ENFORCE_WORKTREE_ON)"

    if [ -z "$E10_OFF" ] || [ -z "$E10_ON" ]; then
        fail "E10-setup: no runnable OFF/ON echo command could be read out of ${EWO_ABS##*/} — neither the standard WORKFLOW_ENFORCE_WORKFLOW_OFF form nor the WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY fallback is shown as a command (OFF='${E10_OFF:-<none>}' ON='${E10_ON:-<none>}') — the sentinels are named but never shown as a command, so a blocked session has to reconstruct the exact spelling by hand"
    else
        pass "E10-setup: both WORKFLOW_OFF commands were extracted from the skill verbatim (OFF form graded: $E10_OFF_FORM — $E10_OFF)"

        E10_SID="e10sid2037"
        E10_BEFORE="$(e10_markers "$E10_SID")"
        if [ -z "$E10_BEFORE" ]; then
            pass "E10a: no marker exists for the session before the skill's OFF command runs"
        else
            fail "E10a: markers already present before anything ran ($E10_BEFORE) — E10b would pass on a handler that writes nothing"
        fi

        e10_emit "$E10_SID" "$E10_OFF"
        E10_AFTER_OFF="$(e10_markers "$E10_SID")"
        case "$E10_AFTER_OFF" in
            *workflow-off*)
                pass "E10b: the skill's OFF command creates the session's workflow-off marker ($E10_AFTER_OFF)" ;;
            *)
                fail "E10b: running the skill's own OFF command left no workflow-off marker (got '${E10_AFTER_OFF:-<none>}') — the documented escape hatch reports success and suspends nothing, exactly when the session cannot afford to find that out later" ;;
        esac

        # Scope: the marker belongs to the session that emitted it. A shared or fixed name
        # would satisfy E10b and silently disarm enforcement for every concurrent session.
        E10_OTHER="$(e10_markers "othersid2037")"
        if [ -z "$E10_OTHER" ]; then
            pass "E10c: with the hatch open for one session, a DIFFERENT session has no marker"
        else
            fail "E10c: a second session picked up markers ($E10_OTHER) while the hatch belonged to $E10_SID — the bypass is not session-scoped"
        fi

        e10_emit "$E10_SID" "$E10_ON"
        E10_AFTER_ON="$(e10_markers "$E10_SID")"
        case "$E10_AFTER_ON" in
            *workflow-off*)
                fail "E10d: the skill's ON command left the workflow-off marker in place ($E10_AFTER_ON) — enforcement stays suspended for the rest of the session even though the reader did what the page said" ;;
            *)
                pass "E10d: the skill's ON command removes the marker, restoring enforcement" ;;
        esac

        # Idempotency: E8b requires the page to call the restore obligatory ("emit it even
        # if the work failed"). A reader following that instruction will sometimes emit ON
        # twice; the second one must be a silent no-op — and "silent" is half the claim, so
        # the handler's own signals are graded alongside the filesystem state.
        E10_TWICE_SIG="$(e10_emit "$E10_SID" "$E10_ON")"
        E10_TWICE="$(e10_markers "$E10_SID")"
        case "$E10_TWICE" in
            *workflow-off*)
                fail "E10e: a repeated restore re-created the marker ($E10_TWICE)" ;;
            *)
                case "$E10_TWICE_SIG" in
                    *FATAL*)
                        fail "E10e: a repeated restore left no marker but signalled fatal ($(printf '%s' "$E10_TWICE_SIG" | tr '\n' ' ' | cut -c1-200)) — a reader who follows the obligatory-restore instruction twice is told the restore failed, and the natural next move is to reach for the OFF sentinel again" ;;
                    *)
                        pass "E10e: a repeated restore is a silent no-op — no marker, no fatal signal" ;;
                esac ;;
        esac
    fi

    # The WORKTREE_OFF twin. E4e moves its sentinels into the same skill and E4d takes them
    # out of rules/worktree.md, so if they arrived as prose rather than as a working pair,
    # E9 still passes: the unconditional rule routes here correctly, to a dead command.
    if [ -z "$E10_WT_OFF" ] || [ -z "$E10_WT_ON" ]; then
        fail "E10f-setup: no runnable WORKTREE_OFF/ON echo command could be read out of the skill (OFF='${E10_WT_OFF:-<none>}' ON='${E10_WT_ON:-<none>}') — E9 routes a blocked session here and the procedure it lands on is not runnable"
    else
        E10_WSID="e10wsid2037"
        e10_emit "$E10_WSID" "$E10_WT_OFF"
        E10_WT_AFTER="$(e10_markers "$E10_WSID")"
        case "$E10_WT_AFTER" in
            *worktree-off*)
                pass "E10f: the skill's WORKTREE_OFF command creates the session's worktree-off marker ($E10_WT_AFTER)" ;;
            *)
                fail "E10f: the relocated WORKTREE_OFF command left no worktree-off marker (got '${E10_WT_AFTER:-<none>}') — the hatch E9 routes to does not work" ;;
        esac

        e10_emit "$E10_WSID" "$E10_WT_ON" >/dev/null
        E10_WT_RESTORED="$(e10_markers "$E10_WSID")"
        case "$E10_WT_RESTORED" in
            *worktree-off*)
                fail "E10g: the relocated WORKTREE_ON command left the worktree-off marker in place ($E10_WT_RESTORED)" ;;
            *)
                pass "E10g: the relocated WORKTREE_ON command restores enforcement" ;;
        esac
    fi
fi

echo ""
echo "=== E11: the relocated WORKTREE_OFF actually moves the guard a blocked session is stuck in ==="

# E10 stops at the marker; the guard is the half a stuck session feels. A handler that
# wrote the marker under a name enforce-worktree.js no longer consults would leave every
# E10 case green while the documented hatch changed nothing — and this is the one hatch
# whose reader is, by definition, already blocked.

E11_HOOK="$(node_path "$AGENTS_DIR/hooks/enforce-worktree.js")"

# A main-worktree repo with ENFORCE_WORKTREE=on: the state the hatch exists to escape.
E11_REPO="$BASE/e11-repo"
mkdir -p "$E11_REPO"
git -C "$E11_REPO" init -q -b main 2>/dev/null
git -C "$E11_REPO" config user.email "test@example.com"
git -C "$E11_REPO" config user.name "Test"
git -C "$E11_REPO" config core.hooksPath /dev/null
git -C "$E11_REPO" commit --allow-empty --no-verify -q -m init 2>/dev/null
E11_REPO_N="$(node_path "$E11_REPO")"

# e11_write_blocked <sid> -> "block" or "allow" for an ordinary write from the main worktree.
e11_write_blocked() {
    local sid="$1" payload out
    payload="$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:"Write",tool_input:{file_path:process.argv[2]+"/probe.txt",content:"x"}}))' "$sid" "$E11_REPO_N")"
    out="$( cd "$E11_REPO" && printf '%s' "$payload" | E10_run_with_timeout 30 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$(node_path "$E10_WF")" \
        "WORKFLOW_PLANS_DIR=$(node_path "$E10_PLANS")" \
        node "$E11_HOOK" 2>&1 )"
    case "$out" in
        *'"decision":"block"'*) echo "block" ;;
        *) echo "allow" ;;
    esac
}

if [ ! -f "$AGENTS_DIR/hooks/enforce-worktree.js" ]; then
    fail "E11: IMPLEMENTATION MISSING: hooks/enforce-worktree.js — the guard the WORKTREE_OFF hatch exists to suspend"
elif [ -z "${E10_WT_OFF:-}" ] || [ -z "${E10_WT_ON:-}" ]; then
    fail "E11: the relocated WORKTREE_OFF/ON commands could not be extracted (see E10f-setup), so the guard sequence cannot be driven from the document"
else
    E11_SID="e11sid2037"
    E11_BEFORE="$(e11_write_blocked "$E11_SID")"
    if [ "$E11_BEFORE" = "block" ]; then
        pass "E11a: before the hatch is opened, a main-worktree write is blocked"
    else
        fail "E11a: the write was already allowed with no marker — E11b would prove nothing about the hatch"
    fi

    e10_emit "$E11_SID" "$E10_WT_OFF" >/dev/null
    E11_INSIDE="$(e11_write_blocked "$E11_SID")"
    if [ "$E11_INSIDE" = "allow" ]; then
        pass "E11b: after the skill's WORKTREE_OFF command, the same write is allowed — the marker the skill writes is the one the guard reads"
    else
        fail "E11b: the write is still blocked after running the skill's own WORKTREE_OFF command — the documented hatch leaves the session exactly as stuck, with no signal that it did nothing"
    fi

    E11_OTHER="$(e11_write_blocked "othere11sid")"
    if [ "$E11_OTHER" = "block" ]; then
        pass "E11c: with the hatch open for one session, a DIFFERENT session is still blocked"
    else
        fail "E11c: a second session was allowed through while the hatch belonged to $E11_SID — one escape disarms the guard for every concurrent session"
    fi

    e10_emit "$E11_SID" "$E10_WT_ON" >/dev/null
    E11_AFTER="$(e11_write_blocked "$E11_SID")"
    if [ "$E11_AFTER" = "block" ]; then
        pass "E11d: after the skill's restore command, the write is blocked again — the hatch does not outlive it"
    else
        fail "E11d: the bypass survived the restore command, so every later write in the session runs unguarded"
    fi
fi
