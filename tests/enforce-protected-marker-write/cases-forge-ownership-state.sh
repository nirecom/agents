#!/usr/bin/env bash
# Tests: hooks/block-clearance-token-write.js, hooks/lib/session-markers.js
# Tags: session-marker, protected-basename, gh, ownership, forge-state, scope:common
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Section O (#2053) - the forge-ownership session state files.
#
# A Bash-tool write to <sid>.gh-login / <sid>.gh-env / <sid>.gh-auth-dirty (the
# ownership-guard's cache) can forge ownership proof or clear the auth-dirty
# flag, so both marker-gate.js (suffix system) and bash-target-context/
# classify.js (mention system) must independently protect them.

run_O_forge_ownership_state() {
    local probe="$SANDBOX/forge-state-probe.js" out
    local CLASSIFY_NODE="$_AGENTS_DIR_NODE/hooks/block-clearance-token-write/bash-target-context/classify.js"
    local kind

    cat > "$probe" <<'PROBE_EOF'
"use strict";
const p = require(process.argv[2]);
const out = [];
const kinds = p.FORGE_OWNERSHIP_STATE_KINDS || [];
out.push(`exported=${Array.isArray(p.FORGE_OWNERSHIP_STATE_KINDS)}`);
out.push(`count=${kinds.length}`);
out.push(`names=${[...kinds].sort().join(",")}`);
// The three kinds must reach the classifier, the suffix list, the regex and the
// mention gate in BOTH the bare and the .tmp form - same contract every other
// protected kind already satisfies (CPR-ORTH).
for (const k of kinds) {
  for (const sfx of ["", ".tmp"]) {
    const base = "s1." + k + sfx;
    out.push(`classify ${k}${sfx}=${p.classifyProtectedPath(base)}`);
    out.push(`suffixlist ${k}${sfx}=${p.PROTECTED_MARKER_SUFFIXES.includes("." + k + sfx)}`);
    out.push(`re ${k}${sfx}=${p.PROTECTED_MARKER_BASENAME_RE.test(base)}`);
    out.push(`mention ${k}${sfx}=${p.mentionsProtectedName(base)}`);
  }
}
// The list grew by exactly 3 kinds x {bare,.tmp}: not fewer (a kind left
// unguarded) and not more (a hand-edited entry nobody derived).
const want = 2 * (p.SESSION_MARKER_KINDS.length + kinds.length);
out.push(`suffixcount-exact=${p.PROTECTED_MARKER_SUFFIXES.length === want}`);
out.push(`grew-by=${p.PROTECTED_MARKER_SUFFIXES.length - 2 * p.SESSION_MARKER_KINDS.length}`);
// The forge kinds are state, not clearance markers: they must NOT have been
// smuggled into SESSION_MARKER_KINDS, which is what session-markers.js reads.
out.push(`not-session-kinds=${kinds.every((k) => !p.SESSION_MARKER_KINDS.includes(k))}`);
// The pre-existing kinds keep their verdicts unchanged.
out.push(`workflow-off-intact=${p.classifyProtectedPath("s1.workflow-off")}`);
out.push(`worktree-off-intact=${p.classifyProtectedPath("s1.worktree-off")}`);
// Bare words must not arm the mention gate: `.gh-env` is a suffix of a session
// file, but "gh-env" as plain prose in a commit message is not a write.
out.push(`mention-bareword=${p.mentionsProtectedName("gh-login")}`);
process.stdout.write(out.join("\n"));
PROBE_EOF

    out=$("$RWT" 15 node "$probe" "$PB_NODE" 2>/dev/null)
    if [ -z "$out" ]; then
        fail "O1 forge-state probe produced no output" \
             "node or hooks/lib/protected-basenames.js unusable (FORGE_OWNERSHIP_STATE_KINDS missing?)"
        rm -f "$probe" 2>/dev/null || true
        return
    fi
    _o_line() { printf '%s\n' "$out" | grep -F "$1" | head -1; }

    assert_eq "O1 FORGE_OWNERSHIP_STATE_KINDS is exported" "exported=true" "$(_o_line 'exported=')"
    assert_eq "O1 it holds exactly 3 kinds" "count=3" "$(_o_line 'count=')"
    assert_eq "O1 and they are the three the guard writes" \
        "names=gh-auth-dirty,gh-env,gh-login" "$(_o_line 'names=')"

    for kind in gh-login gh-env gh-auth-dirty; do
        assert_eq "O2 [$kind] classifies as a protected path" \
            "classify $kind=marker" "$(_o_line "classify $kind=")"
        assert_eq "O2 [$kind] .tmp classifies too (write-then-rename)" \
            "classify $kind.tmp=marker" "$(_o_line "classify $kind.tmp=")"
        assert_eq "O2 [$kind] is in PROTECTED_MARKER_SUFFIXES" \
            "suffixlist $kind=true" "$(_o_line "suffixlist $kind=")"
        assert_eq "O2 [$kind] .tmp is in PROTECTED_MARKER_SUFFIXES" \
            "suffixlist $kind.tmp=true" "$(_o_line "suffixlist $kind.tmp=")"
        assert_eq "O2 [$kind] matches the marker regex" "re $kind=true" "$(_o_line "re $kind=")"
    done

    # NOTE for write-code: X5 `markerlist-exact` in cases-ssot.sh derives the
    # expected list from SESSION_MARKER_KINDS alone, so it must be widened to
    # SESSION_MARKER_KINDS + FORGE_OWNERSHIP_STATE_KINDS. O3 pins the arithmetic.
    assert_eq "O3 the suffix list grew by exactly 6 entries" "grew-by=6" "$(_o_line 'grew-by=')"
    assert_eq "O3 and the total is exactly 2 per kind, no strays" \
        "suffixcount-exact=true" "$(_o_line 'suffixcount-exact=')"
    assert_eq "O3 the forge kinds are state, not clearance markers" \
        "not-session-kinds=true" "$(_o_line 'not-session-kinds=')"
    assert_eq "O4 .workflow-off keeps its existing verdict" \
        "workflow-off-intact=marker" "$(_o_line 'workflow-off-intact=')"
    assert_eq "O4 .worktree-off keeps its existing verdict" \
        "worktree-off-intact=marker" "$(_o_line 'worktree-off-intact=')"

    # --- mention system (bash-target-context/classify.js) -------------------
    # Separate assert from the suffix system below: these are two independent
    # enforcement paths, and a kind taught to only one of them is still forgeable
    # through the other. The mention gate is what catches an opaque route (pipe,
    # process substitution) whose target cannot be resolved to a path at all.
    for kind in gh-login gh-env gh-auth-dirty; do
        assert_eq "O5 [$kind] arms the mention gate" \
            "mention $kind=true" "$(_o_line "mention $kind=")"
        assert_eq "O5 [$kind] .tmp arms the mention gate" \
            "mention $kind.tmp=true" "$(_o_line "mention $kind.tmp=")"
    done
    assert_eq "O5 a bare word without the session prefix does not" \
        "mention-bareword=false" "$(_o_line 'mention-bareword=')"
    if [ -f "$AGENTS_DIR/hooks/block-clearance-token-write/bash-target-context/classify.js" ]; then
        if grep -q 'mentionsProtectedName' \
            "$AGENTS_DIR/hooks/block-clearance-token-write/bash-target-context/classify.js"; then
            pass "O5 classify.js still sources the mention gate from the SSOT"
        else
            fail "O5 classify.js no longer imports mentionsProtectedName - the mention set has forked"
        fi
    else
        skip "O5 bash-target-context/classify.js not found"
    fi
    # The gate is only reachable if classify.js is loadable at all.
    if "$RWT" 10 node -e 'require(process.argv[1]);' "$CLASSIFY_NODE" >/dev/null 2>&1; then
        pass "O5 classify.js loads"
    else
        fail "O5 classify.js does not load"
    fi

    # --- suffix system (enforce-worktree/bash-write-scope/marker-gate.js) ---
    # marker-gate.js re-exports the SSOT regex; if it were carrying its own copy
    # the three new names would be invisible to every enforce-worktree allow path.
    for kind in gh-login gh-env gh-auth-dirty; do
        if "$RWT" 10 node -e \
            'const g=require(process.argv[1]);process.exit(g.bashTargetsHitProtectedMarker([process.argv[2]])?0:1)' \
            "$MARKER_GATE_NODE" "$WFDIR/$SID.$kind" >/dev/null 2>&1; then
            pass "O6 [$kind] marker-gate skips every allow fast-path"
        else
            fail "O6 [$kind] marker-gate does not recognise it" "bashTargetsHitProtectedMarker returned false"
        fi
        if "$RWT" 10 node -e \
            'const g=require(process.argv[1]);process.exit(g.bashTargetsHitProtectedMarker([process.argv[2]])?0:1)' \
            "$MARKER_GATE_NODE" "$WFDIR/$SID.$kind.tmp" >/dev/null 2>&1; then
            pass "O6 [$kind] .tmp likewise"
        else
            fail "O6 [$kind] .tmp not recognised by marker-gate"
        fi
    done

    # --- end to end, Q-14(e): the write itself must be BLOCKED -------------
    # Run from inside the linked worktree on a feature branch, the location where
    # enforce-worktree.js would otherwise approve everything.
    for kind in gh-login gh-env gh-auth-dirty; do
        assert_block "O7 [$kind] Write is blocked" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$WFDIR/$SID.$kind")")"
        assert_block "O7 [$kind] Bash redirect is blocked" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $WFDIR/$SID.$kind" "$LINKED_WT")")"
        assert_block "O7 [$kind] .tmp Bash redirect is blocked" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $WFDIR/$SID.$kind.tmp" "$LINKED_WT")")"
        # rm is a write too: deleting .gh-auth-dirty clears the guard's memory.
        assert_block "O7 [$kind] rm is blocked" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "rm -f $WFDIR/$SID.$kind" "$LINKED_WT")")"
    done

    unset -f _o_line
    rm -f "$probe" 2>/dev/null || true
}

# --- O8: Protection Pattern 1 — the side effect, not just the verdict --------

# WHY: O7 asserts what the classifier SAYS. A classifier that says "block" while
# the surrounding system still performs the write is the only failure mode that
# matters here, and no verdict assertion can see it. Pattern 1 closes that by
# planting a canary, running the guarded action ONLY when the hook did not block,
# and then reading the canary back. A guard that mis-classifies destroys it.

# The three files decide whether a `gh issue create` is waved through, so the
# side effect being prevented is concrete: forging ownership proof (overwrite)
# or erasing the guard's memory of a dirty auth context (delete).

_o8_terminal_input() { # <command> <cwd>
    printf '{"tool_name":"runInTerminal","session_id":"wsid","cwd":"%s","tool_input":{"command":"%s"}}' \
        "$(json_esc "$2")" "$(json_esc "$1")"
}
_o8_commands_input() { # <command> <cwd>  — probed at commands[1], never index 0
    printf '{"tool_name":"runCommands","session_id":"wsid","cwd":"%s","tool_input":{"commands":["echo start","%s"]}}' \
        "$(json_esc "$2")" "$(json_esc "$1")"
}
_o8_shell() { # <target> <mode>
    if [ "$2" = "delete" ]; then printf 'rm -f "%s"' "$1"; else printf 'printf FORGED > "%s"' "$1"; fi
}
_o8_payload() { # <tool> <target> <mode>
    case "$1" in
        Bash)          mk_bash_input "$(_o8_shell "$2" "$3")" "$LINKED_WT" ;;
        runInTerminal) _o8_terminal_input "$(_o8_shell "$2" "$3")" "$LINKED_WT" ;;
        runCommands)   _o8_commands_input "$(_o8_shell "$2" "$3")" "$LINKED_WT" ;;
        *)             mk_tool_input "$1" "$LINKED_WT" file_path "$2" ;;
    esac
}

# _o8_guarded <label> <tool> <target> <mode>
# The conditional execution IS the test: the action runs exactly when the hook
# failed to block, so an intact canary means the protection held end to end.
_o8_guarded() {
    local label="$1" tool="$2" target="$3" mode="$4" verdict raw
    printf 'CANARY' > "$target"
    raw="$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_o8_payload "$tool" "$target" "$mode")")"
    verdict="$(classify "$raw")"
    if [ "$verdict" != "block" ]; then
        ( eval "$(_o8_shell "$target" "$mode")" ) >/dev/null 2>&1 || true
    fi
    if [ ! -f "$target" ]; then
        fail "$label - the state file was DELETED (verdict=$verdict)"
    elif [ "$(cat "$target" 2>/dev/null)" != "CANARY" ]; then
        fail "$label - the state file was OVERWRITTEN (verdict=$verdict)"
    else
        pass "$label - canary intact (verdict=$verdict)"
    fi
    rm -f "$target" 2>/dev/null || true
}

run_O8_forge_state_side_effects() {
    local kind tool target

    # Self-check first: if `eval` of the action could not damage a file, every row
    # below would pass no matter what the hook decided. Proven on an unprotected
    # name, so the mechanism is shown to be live before it is trusted.
    local decoy="$SANDBOX/o8-selfcheck.txt"
    printf 'CANARY' > "$decoy"
    ( eval "$(_o8_shell "$decoy" "write")" ) >/dev/null 2>&1 || true
    if [ "$(cat "$decoy" 2>/dev/null)" = "FORGED" ]; then
        pass "O8-0 the action mechanism really overwrites an unprotected file (self-check)"
    else
        fail "O8-0 action self-check - the overwrite did not fire, so O8 would be vacuous"
    fi
    ( eval "$(_o8_shell "$decoy" "delete")" ) >/dev/null 2>&1 || true
    if [ ! -f "$decoy" ]; then
        pass "O8-0 the action mechanism really deletes an unprotected file (self-check)"
    else
        fail "O8-0 delete self-check - the rm did not fire, so the deletion rows would be vacuous"
    fi
    rm -f "$decoy" 2>/dev/null || true

    for kind in gh-login gh-env gh-auth-dirty; do
        # The file-payload family. `.tmp` is the write-then-rename spelling: a
        # forged proof staged there and renamed is the same forgery.
        for tool in Write Edit MultiEdit editFiles; do
            _o8_guarded "O8 [$kind] $tool leaves the state file untouched" \
                "$tool" "$WFDIR/$SID.$kind" write
            _o8_guarded "O8 [$kind] $tool .tmp leaves the staged file untouched" \
                "$tool" "$WFDIR/$SID.$kind.tmp" write
        done
        # The command family, which additionally has a deletion form: removing
        # .gh-auth-dirty clears the flag the guard set, which re-opens the very
        # window the guard closed (CPR-ORTH: same treatment for all three kinds).
        for tool in Bash runInTerminal runCommands; do
            _o8_guarded "O8 [$kind] $tool redirect leaves the state file untouched" \
                "$tool" "$WFDIR/$SID.$kind" write
            _o8_guarded "O8 [$kind] $tool .tmp redirect leaves the staged file untouched" \
                "$tool" "$WFDIR/$SID.$kind.tmp" write
            _o8_guarded "O8 [$kind] $tool deletion leaves the state file in place" \
                "$tool" "$WFDIR/$SID.$kind" delete
        done
    done

    # CPR-ORTH counterweight: an ordinary file under the same directory must
    # still be writable, or the protection has simply frozen the state dir and
    # every row above would pass for the wrong reason.
    local ordinary="$WFDIR/$SID.notes.txt"
    printf 'CANARY' > "$ordinary"
    local raw verdict
    raw="$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_o8_payload Bash "$ordinary" write)")"
    verdict="$(classify "$raw")"
    if [ "$verdict" != "block" ]; then
        ( eval "$(_o8_shell "$ordinary" write)" ) >/dev/null 2>&1 || true
    fi
    if [ "$(cat "$ordinary" 2>/dev/null)" = "FORGED" ]; then
        pass "O8-9 an ordinary file in the same directory is still writable"
    else
        fail "O8-9 an ordinary file in the same directory is still writable - verdict=$verdict, the guard over-blocks"
    fi
    rm -f "$ordinary" 2>/dev/null || true
}
