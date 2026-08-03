#!/usr/bin/env bash
# Part of tests/fix-1780-round14-mint-lock.sh (rules/coding/file-split.md).
# THE LOCK FILE IS PROTECTED STATE — round-14 HIGH-2.
#
# A mutex whose file anyone may create or delete is not a mutex. Both directions
# are live attacks on the OFF path, and they are opposites (CPR-5 — the guard
# must cover the pair, not one side):
#
#   CREATE  — pre-create `<sid>.off-clearance.mint.lock.tmp` and every mint and
#             every claim for that SID fails to acquire for as long as it exists.
#             The mint reports UNAVAILABLE and the shim blocks `lock-busy`: a
#             self-inflicted denial of the entire clearance mechanism, achieved
#             by touching one file with an innocuous `.tmp` name.
#   DELETE  — remove it mid-transition and the two participants are unsynchronized
#             again, which is precisely the race the round-14 HIGH fix closes.
#
# So the lock basename must be protected by the SAME SSOT that protects the token
# (hooks/lib/protected-basenames.js), and the SSOT and the module that NAMES the
# file must not be able to drift apart. P1/P2 assert exactly that cross-module
# agreement: the string is taken from off-clearance-mint-lock.js's OWN
# lockPathFor() and handed to the classifier — not hard-coded on both sides,
# which would keep passing after a rename on one side only.
#
# P6 is the boundary that keeps this from being a blanket `.mint.lock.tmp` ban:
# a lock beside an UNRELATED file is ordinary scratch state and must stay
# writable. What is protected is the clearance token's lock specifically.

# _p_run_hook <stdin-json> → "block" | "approve" | "other:<raw>"
_p_run_hook() {
    local out rc
    out=$(CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$BLOCK_HOOK" <<< "$2" 2>/dev/null)
    rc=$?
    out=$(printf '%s' "$out" | tr -d '\r\n')
    if [ "$rc" -ne 0 ]; then printf 'crash:%s' "$rc"; return; fi
    case "$out" in
        *'"decision":"block"'*)   printf 'block' ;;
        *'"decision":"approve"'*) printf 'approve' ;;
        *)                        printf 'other:%s' "$out" ;;
    esac
}

# _p_write_input <path> — Write-tool PreToolUse payload
_p_write_input() {
    "$RWT" 10 node -e '
process.stdout.write(JSON.stringify({tool_name:"Write",session_id:"wsid",
  tool_input:{file_path:process.argv[1],content:"x"}}));' "$1"
}

# _p_bash_input <command> — Bash-tool PreToolUse payload
_p_bash_input() {
    "$RWT" 10 node -e '
process.stdout.write(JSON.stringify({tool_name:"Bash",session_id:"wsid",
  tool_input:{command:process.argv[1]}}));' "$1"
}

run_P_lock_protected() {
    local tmp tn out lockpath
    tmp=$(make_tmp); tn=$(node_path "$tmp")

    # P1/P2/P3 — cross-module SSOT agreement, driven by lockPathFor() itself.
    out=$("$RWT" 20 node -e '
"use strict";
const path = require("path");
const { lockPathFor } = require(process.argv[1]);
const B = require(process.argv[2]);
const tok = path.join(process.argv[3], "mintlocksid.off-clearance");
const lp = lockPathFor(tok);
console.log("LOCKPATH=" + lp);
console.log("P1_path_kind=" + B.classifyProtectedPath(lp));
console.log("P2_bash_kind=" + B.classifyProtectedBashToken(lp));
console.log("P2_bare_basename_kind=" + B.classifyProtectedBashToken(path.basename(lp)));
console.log("P3_in_ssot=" + (B.OFF_CLEARANCE_TOKEN_SUFFIXES.indexOf(".off-clearance.mint.lock.tmp") >= 0 ? "yes" : "no"));
// The suffix list is the SSOT; the lock name must be derivable FROM it, so a
// rename of lockPathFor() without a matching SSOT entry fails here.
console.log("P3_derives=" + (B.OFF_CLEARANCE_TOKEN_SUFFIXES.some(function (s) { return lp.endsWith(s); }) ? "yes" : "no"));
' "$LOCK_MOD_NODE" "$BASENAMES_NODE" "$tn" 2>&1)

    lockpath=$(field LOCKPATH "$out")
    assert_eq "P1 lockPathFor() output classifies as a protected TOKEN path" "token" "$(field P1_path_kind "$out")"
    assert_eq "P2 same string classifies as a protected TOKEN bash word"     "token" "$(field P2_bash_kind "$out")"
    assert_eq "P2 bare basename (no directory) classifies too"               "token" "$(field P2_bare_basename_kind "$out")"
    assert_eq "P3 .off-clearance.mint.lock.tmp is in the suffix SSOT"        "yes"   "$(field P3_in_ssot "$out")"
    assert_eq "P3 the minted lock NAME is derivable from that SSOT (no drift)" "yes" "$(field P3_derives "$out")"

    if [ -z "$lockpath" ]; then
        fail "P4-P6 harness: lockPathFor() produced no path"
        rm -rf "$tmp"; return
    fi

    # P4/P5a/P5b — the three ways an agent could reach the lock file. Each is a
    # DIFFERENT tool surface of the same hook, so covering one proves nothing
    # about the others (CPR-5).
    assert_eq "P4 Write tool to the lock path is blocked" "block" \
        "$(_p_run_hook "$tn" "$(_p_write_input "$lockpath")")"
    assert_eq "P5a bash redirect creating the lock is blocked" "block" \
        "$(_p_run_hook "$tn" "$(_p_bash_input "printf x > $lockpath")")"
    assert_eq "P5b bash rm of the lock (the DELETE direction) is blocked" "block" \
        "$(_p_run_hook "$tn" "$(_p_bash_input "rm -f $lockpath")")"

    # P6 — BOUNDARY. A `.mint.lock.tmp` that is NOT a clearance-token lock is
    # ordinary scratch state; blocking it would be a false positive on unrelated
    # work and would mean the guard keys on the wrong part of the name.
    assert_eq "P6 boundary: an unrelated .mint.lock.tmp stays writable" "approve" \
        "$(_p_run_hook "$tn" "$(_p_bash_input "printf x > $tn/build-cache.mint.lock.tmp")")"

    rm -rf "$tmp"
}
