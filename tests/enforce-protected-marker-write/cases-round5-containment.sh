#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-5 codex-HIGH (containment SSOT) and MEDIUM-7 (detection-direction gate).
#
# THE HOLE. Two entrypoints ask the SAME question about the SAME directory:
#   hooks/block-clearance-token-write/bash-target-context.js — is this glob's dir
#     inside the workflow dir? (if yes, a pure wildcard target fails closed)
#   hooks/enforce-worktree/bash-write-scope/marker-gate.js — is this write target
#     inside the workflow dir? (if yes, it gets the allow fast-path)
# They had drifted into two implementations. The block side was LEXICAL and folded
# case on `process.platform === "win32"` alone, so:
#   - a symlinked alias of the workflow dir read as "outside", and a pure glob
#     through that alias (`<alias>/*`) is exempt from the basename matcher by
#     design — together, a forge route the qualifier exists to close;
#   - a case-only spelling difference on a case-insensitive NON-Windows volume
#     (macOS by default, a Windows share mounted in WSL) also read as "outside".
# Both are now hooks/lib/path-containment.js, used by both sides.
#
# WHAT IS ASSERTED. Sharing is checked by FUNCTION IDENTITY, not by equivalent
# behaviour: a re-forked copy that happens to agree today would pass a behavioural
# check and fail an identity one. Behaviour is then asserted as AGREEMENT between
# the two call sites, with the expected answer taken from the filesystem itself
# (pc.isCaseInsensitiveFsAt) rather than hardcoded per platform — CPR-UNV.
#
# MEDIUM-7 is the orthogonality half: bashTargetsHitProtectedMarker() is a
# DETECTION predicate ("skip every allow fast-path"), so it must answer true for
# BOTH protected families and for a target it could not parse; its permission-
# direction sibling must answer false for the same three inputs. Asserting the two
# directions side by side is what keeps a future edit from "simplifying" them into
# one convention.
#
# Module-level, not hook-level, on purpose: the disagreement is between two
# library call sites, and only a call-site-level assertion can catch it before it
# becomes a verdict difference. The E2E half (C-E1/C-E2) then confirms the
# qualifier is really wired into the shipped hook verdict.

# _r5_kv <key>  -> value from the probe output captured in $_R5_PROBE_OUT
_r5_kv() {
    local line
    line=$(printf '%s\n' "$_R5_PROBE_OUT" | grep -m1 "^$1=") || true
    printf '%s' "${line#*=}"
}
_r5_expect() { assert_eq "R5-C $1 == $2" "$2" "$(_r5_kv "$1")"; }

# _r5_try_symlink <target> <linkpath>: plain ln -s degrades to a directory COPY on
# Git Bash/MSYS, which would make the alias cases assert nothing, so the result is
# verified with -L and the nativestrict variant retried.
_r5_try_symlink() {
    ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    rm -r -f "$2" 2>/dev/null
    MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    return 1
}

run_R5_containment() {
    local probe="$AGENTS_DIR/tests/enforce-protected-marker-write/round5-containment-probe.js"
    if [ ! -f "$probe" ]; then
        fail "R5-C probe helper missing at $probe - containment section is vacuous"
        return
    fi

    local root alias_dir outside alias_ok=no
    root=$(make_tmp)
    mkdir -p "$root/real/wf" "$root/outside"
    outside="$root/outside"
    alias_dir="$root/aliaslink"
    _r5_try_symlink "$root/real/wf" "$alias_dir" && alias_ok=yes

    local wf_n alias_n out_n root_wf
    root_wf="$root/real/wf"
    wf_n=$(node_path "$root_wf"); alias_n=$(node_path "$alias_dir"); out_n=$(node_path "$outside")

    _R5_PROBE_OUT=$(CLAUDE_WORKFLOW_DIR="$wf_n" WORKFLOW_PLANS_DIR="$wf_n" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 20 node "$probe" \
        "$_AGENTS_DIR_NODE" "$wf_n" "$alias_n" "$out_n" 2>/dev/null)
    if [ -z "$_R5_PROBE_OUT" ]; then
        fail "R5-C containment probe produced no output (crash/timeout) - section vacuous"
        cleanup_tmp "$root"
        return
    fi

    # (1) one implementation, shared by identity
    _r5_expect id_isContainedUnder true
    _r5_expect id_realResolve true
    _r5_expect id_caseProbe true

    # (2) the two call sites agree - symlinked alias of the workflow dir
    if [ "$alias_ok" = yes ]; then
        _r5_expect alias_glob true
        _r5_expect alias_gate true
    else
        skip "R5-C alias_glob/alias_gate - no real symlink available here (Windows without developer mode / MSYS winsymlinks); the containment requirement stands, verify on a POSIX host"
    fi

    # (3) the two call sites agree - case-only spelling, expectation read off the
    #     filesystem rather than the platform
    local ci; ci=$(_r5_kv case_expected)
    assert_eq "R5-C case_glob agrees with the volume (case-insensitive=$ci)" "$ci" "$(_r5_kv case_glob)"
    assert_eq "R5-C case_gate agrees with the volume (case-insensitive=$ci)" "$ci" "$(_r5_kv case_gate)"

    # (4) CPR-ORTH counterpart: the shared helper did not widen containment
    _r5_expect outside_glob false
    _r5_expect outside_gate false
    _r5_expect inside_glob true
    _r5_expect inside_gate true

    # (5) E2E: the qualifier is really wired into the shipped hook verdict, so a
    #     pure wildcard aimed through the alias blocks while an ordinary bulk glob
    #     elsewhere keeps working.
    if [ "$alias_ok" = yes ]; then
        assert_block "R5-C E1 pure glob through a symlinked alias of the workflow dir" \
            "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "echo x > $alias_n/*" "$LINKED_WT")")"
    fi
    assert_approve "R5-C E2 ordinary bulk glob outside the workflow dir stays allowed" \
        "$(run_hook_cwd "$LINKED_WT" "$wf_n" "$(mk_bash_input "rm -rf $out_n/*" "$LINKED_WT")")"

    cleanup_tmp "$root"
}

run_R5_marker_gate() {
    if [ -z "${_R5_PROBE_OUT:-}" ]; then
        fail "R5-M marker-gate assertions need the containment probe output (run_R5_containment must run first)"
        return
    fi
    # DETECTION direction: true = "skip every allow fast-path".
    _r5_expect det_marker true
    _r5_expect det_token true          # MEDIUM-7: the token family was ignored
    _r5_expect det_token_bare true
    _r5_expect det_malformed_null true     # MEDIUM-7: malformed returned false
    _r5_expect det_malformed_nopath true
    _r5_expect det_malformed_mixed true
    # CPR-ORTH counterparts: an ordinary target must NOT arm the gate.
    _r5_expect det_plain false
    _r5_expect det_empty false
    # PERMISSION direction: the same three inputs answer the opposite way.
    _r5_expect perm_marker false
    _r5_expect perm_token false
    _r5_expect perm_malformed false
}
