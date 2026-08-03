#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-13 / codex security scanner "C": THE DETECTION DIRECTION OF CONTAINMENT.
#
# THE HOLE. hooks/block-clearance-token-write/bash-target-context.js asks
# hooks/lib/path-containment.js `resolvesUnder()` whether a write target's
# DIRECTORY lands at/under the workflow dir. That question is the sole qualifier
# behind the N-2 exception: a pure-wildcard basename (`<wf>/*`, `<wf>/s1*`)
# commits no literal character to a protected suffix, so
# ../../hooks/lib/basename-glob-normalize.js reports it as a NON-match by design
# (otherwise `rm -rf build/*` would block). The exception is only safe while such
# a glob cannot land on a protected file — and containment is what guarantees it.
#
# resolvesUnder() used to answer a single hardcoded `false` whenever containment
# could not be PROVEN — an unresolvable path, or a symlink chain that trips
# MAX_SYMLINK_HOPS and makes realResolve() throw. For the PERMISSION-direction
# caller (hooks/enforce-worktree/bash-write-scope/marker-gate.js) that is
# correct: false = deny the fast-path = fail closed. For THIS caller it is
# fail-OPEN: false = the qualifier never arms = the glob is approved with none of
# the scrutiny the qualifier exists to add.
#
# THE ATTACK (Pattern 2 structure). Precondition: an attacker-crafted circular
# symlink pair — or a chain longer than MAX_SYMLINK_HOPS — as an ANCESTOR
# directory of the write target, inside the workflow dir. Action: a pure-wildcard
# write through it (`echo x > <wf>/loopA/*`). Pre-fix assertion: ALLOW.
# What that buys — a glob cannot CREATE a file, so this is not a marker forge; it
# is a CONTENT forge on the UNSIGNED clearance token minted by
# bin/request-off-clearance (rewriting a live token can flip `target` /
# `claimed_target`) and a clean truncation DoS on all clearance state.
#
# THE FIX asserted here: every call site in bash-target-context.js now passes
# `onUnknown: true`, so "cannot prove" ARMS the block. The `onUnknown` contract
# itself (mandatory, boolean, returned verbatim, inert on provable input) is
# asserted separately and exhaustively in
# ../fix-1780-round13-resolves-under-contract.sh; what is asserted HERE is that
# this hook's three call sites really carry the detection direction, and that the
# shipped hook VERDICT changes with them.
#
# BOTH DIRECTIONS (Pattern 4). Every crafted row is paired with its sanctioned
# counterpart: the plain resolvable spelling inside the workflow dir must still
# block (the pre-fix control — this is not a new rule), and the plain resolvable
# spelling outside it must still be APPROVED (the fix must not become "every glob
# blocks"). The one row that is neither — an unresolvable ancestor OUTSIDE the
# workflow dir — is pinned as an ACCEPTED, BOUNDED over-block rather than left
# unstated, in the same spirit as run_R10_accepted_overblock.

# _r13_try_symlink <target> <linkpath>: plain `ln -s` degrades to a directory
# COPY on Git Bash/MSYS, which would make every crafted row resolvable and assert
# nothing. Verified with -L, nativestrict retried. Same helper shape as
# ./cases-round5-containment.sh.
_r13_try_symlink() {
    ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    rm -r -f "$2" 2>/dev/null
    MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    return 1
}

# _r13_deep_chain <dir> <prefix> <count>: a LINEAR chain longer than
# MAX_SYMLINK_HOPS ending at a nonexistent tail. The OS cannot short-circuit it
# (the final target never exists), so realResolve() must walk it link by link and
# trip its own hop cap. Built back-to-front.
_r13_deep_chain() {
    local dir="$1" pre="$2" n="$3" i
    _r13_try_symlink "$dir/nowhere" "$dir/${pre}$n" || return 1
    i=$((n - 1))
    while [ "$i" -ge 0 ]; do
        _r13_try_symlink "$dir/${pre}$((i + 1))" "$dir/${pre}$i" || return 1
        i=$((i - 1))
    done
    return 0
}

_r13_kv() {
    local line
    line=$(printf '%s\n' "$_R13_PROBE_OUT" | grep -m1 "^$1=") || true
    printf '%s' "${line#*=}"
}
_r13_expect() { assert_eq "R13 $1 == $2" "$2" "$(_r13_kv "$1")"; }

run_R13_onunknown_direction() {
    local probe="$AGENTS_DIR/tests/enforce-protected-marker-write/round13-onunknown-probe.js"
    if [ ! -f "$probe" ]; then
        fail "R13 probe helper missing at $probe - the whole section is vacuous"
        return
    fi

    # Fixture: a throwaway workflow dir holding two unresolvable ancestors, plus
    # an ordinary outside dir and an unresolvable outside dir. Never the real
    # ~/.claude/projects/workflow (rules/test/fixture-isolation.md).
    local root wf outside wf_n loop_n deep_n outloop_n out_n
    root=$(make_tmp)
    wf="$root/wf"; outside="$root/outside"
    mkdir -p "$wf" "$outside"

    _r13_try_symlink "$wf/loopB" "$wf/loopA" && _r13_try_symlink "$wf/loopA" "$wf/loopB"
    _r13_deep_chain "$wf" "hop" 44 || true
    _r13_try_symlink "$outside/oloopB" "$outside/oloopA" && \
        _r13_try_symlink "$outside/oloopA" "$outside/oloopB"

    wf_n=$(node_path "$wf")
    loop_n=$(node_path "$wf/loopA")
    deep_n=$(node_path "$wf/hop0")
    outloop_n=$(node_path "$outside/oloopA")
    out_n=$(node_path "$outside")

    _R13_PROBE_OUT=$(CLAUDE_WORKFLOW_DIR="$wf_n" WORKFLOW_PLANS_DIR="$wf_n" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 25 node "$probe" \
        "$_AGENTS_DIR_NODE" "$wf_n" "$loop_n" "$deep_n" "$outloop_n" "$out_n" 2>/dev/null)
    if [ -z "$_R13_PROBE_OUT" ]; then
        fail "R13 onUnknown probe produced no output (crash/timeout) - section vacuous"
        cleanup_tmp "$root"
        return
    fi

    # ---- (1) the sanctioned baseline, both directions -----------------------
    # These hold on every host and are what keeps the crafted rows honest: the
    # qualifier must already say "inside" for a plain glob in the workflow dir
    # and "outside" for a plain glob elsewhere.
    _r13_expect glob_plain_inside true
    _r13_expect glob_plain_outside false
    _r13_expect dyn_plain_inside true
    _r13_expect dyn_plain_outside false
    _r13_expect text_plain_inside true
    _r13_expect text_plain_outside false

    # ---- (2) the crafted, unresolvable ancestor -----------------------------
    local loop_ok deep_ok outloop_ok
    loop_ok=$(_r13_kv loop_unresolvable)
    deep_ok=$(_r13_kv deep_unresolvable)
    outloop_ok=$(_r13_kv outside_loop_unresolvable)

    if [ "$loop_ok" = true ]; then
        pass "R13 fixture: circular symlink pair under the workflow dir is genuinely unresolvable"
        # THE fix rows. Pre-fix these were false (fail open).
        _r13_expect glob_loop true
        _r13_expect dyn_loop true
        _r13_expect text_loop true
    else
        skip "R13 circular-symlink rows - no real symlink available here (Windows without developer mode / MSYS winsymlinks); the containment requirement stands, verify on a POSIX host"
    fi

    if [ "$deep_ok" = true ]; then
        pass "R13 fixture: >MAX_SYMLINK_HOPS chain under the workflow dir is genuinely unresolvable"
        _r13_expect glob_deep true
    else
        skip "R13 hop-cap row - the >40-hop chain fixture could not be built here; verify on a POSIX host"
    fi

    # ACCEPTED OVER-BLOCK, pinned on purpose (CPR-8 named exception): the
    # detection direction answers "contained" for an unresolvable ancestor
    # ANYWHERE, including outside the workflow dir. The blast radius is bounded —
    # reaching it requires a symlink loop or a >40-hop chain, which no ordinary
    # bulk glob has — and the alternative is the fail-open hole above.
    if [ "$outloop_ok" = true ]; then
        _r13_expect glob_outside_loop true
    else
        skip "R13 accepted-over-block row - outside-loop fixture unavailable here"
    fi

    # ---- (3) E2E: the shipped hook VERDICT moves with the qualifier ---------
    # Module-level agreement is not enough: only a hook-level verdict proves the
    # qualifier is really wired into the decision the tool call receives.
    if [ "$loop_ok" = true ]; then
        assert_block "R13 E1 pure glob through a circular-symlink ancestor inside the workflow dir" \
            "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "echo x > $loop_n/*" "$LINKED_WT")")"
        assert_block "R13 E2 tee through a circular-symlink ancestor inside the workflow dir" \
            "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "echo x | tee $loop_n/s1*" "$LINKED_WT")")"
    fi
    if [ "$deep_ok" = true ]; then
        assert_block "R13 E3 pure glob through a >MAX_SYMLINK_HOPS ancestor inside the workflow dir" \
            "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "echo x > $deep_n/*" "$LINKED_WT")")"
    fi
    # Pre-fix control: the literal spelling blocked before this fix as well.
    assert_block "R13 E4 control: plain glob directly in the workflow dir still blocks" \
        "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "echo x > $wf_n/*" "$LINKED_WT")")"
    # CPR-5 counterpart: ordinary bulk work outside the workflow dir must keep
    # working, or the fix has traded a bypass for an over-block.
    assert_approve "R13 E5 ordinary bulk glob outside the workflow dir stays allowed" \
        "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "rm -rf $out_n/*" "$LINKED_WT")")"
    assert_approve "R13 E6 ordinary redirect glob outside the workflow dir stays allowed" \
        "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "echo x > $out_n/build/*" "$LINKED_WT")")"

    cleanup_tmp "$root"
}
