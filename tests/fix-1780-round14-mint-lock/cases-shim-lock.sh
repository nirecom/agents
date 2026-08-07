#!/usr/bin/env bash
# Part of tests/fix-1780-round14-mint-lock.sh (rules/coding/file-split.md).
# THE SHIM'S CLAIM LIFECYCLE RUNS UNDER THE MINT LOCK — round-14 HIGH.
#
# hooks/supervisor-off-proposal-shim.js used to run its critical section
# (validate the bare token -> exclusive-create `.claimed` -> unlink the bare
# token) with no synchronization against bin/request-off-clearance's mint
# transition, which mutates the very same two paths. Two concrete losses:
#
#   (a) the shim unlinks the bare token BY PATH after validating bytes it read
#       earlier. If a newer mint replaced those bytes in between, the shim
#       destroys a FRESH examiner-approved grant that was never activated.
#   (b) the mint's stale-claim sweep judges `.claimed` by mint_nonce. A claim
#       being created right now for a live grant looks "stale" to a mint that
#       just wrote a different nonce, so the sweep deletes the single-use record
#       and the only audit evidence that the claim happened.
#
# The fix has TWO halves and BOTH are pinned below, because either alone is
# insufficient:
#
#   S2/S3 — the shim TAKES the lock, and a lock it cannot take fails CLOSED with
#           an honest, transient-specific reason (not the generic "no clearance"
#           message, which would send the operator down the wrong recovery path).
#   S4    — inside the lock it RE-READS the token. A lock that merely serializes
#           while the process still acts on its pre-lock read fixes nothing: the
#           bytes it validates, the bytes it copies into `.claimed` and the bytes
#           it unlinks must all be the same generation.
#
# S4 is the load-bearing case. It swaps the token under the held lock and then
# asserts WHICH generation ended up in `.claimed` (via mint_nonce) — an
# assertion that a pre-lock-read implementation cannot pass, and that a
# "no crash / still allowed" style test would miss entirely.

# _s_lock_path <dir> — the on-disk lock for $SID's bare token
_s_lock_path() { printf '%s/%s.off-clearance.mint.lock.tmp' "$1" "$SID"; }
_s_bare_path() { printf '%s/%s.off-clearance' "$1" "$SID"; }
_s_claim_path() { printf '%s/%s.off-clearance.claimed' "$1" "$SID"; }

run_S_shim_lock() {
    local tmp tn res out

    # ---- S1: control. Uncontended, the normal claim lifecycle still completes.
    # Without this, every "block" below could be an unrelated failure of the gate
    # rather than the lock doing its job.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare_token "$tn" "$SID" "nonceA"
    res=$(run_shim "$tn" "$SID" "$WF_BOUND")
    assert_eq  "S1 uncontended claim is ALLOWED (rc=0, no block)" "0|" "$res"
    assert_eq  "S1 .claimed created by the claim step"            "yes" "$(exists_str "$(_s_claim_path "$tmp")")"
    assert_eq  "S1 bare token consumed (single-use)"              "no"  "$(exists_str "$(_s_bare_path "$tmp")")"
    assert_eq  "S1 claim carries the token generation it validated" "nonceA" \
        "$(read_json_field "$(_s_claim_path "$tmp")" mint_nonce)"
    assert_eq  "S1 lock released, not leaked"                     "no"  "$(exists_str "$(_s_lock_path "$tmp")")"
    rm -rf "$tmp"

    # ---- S2: the lock is HELD (as it is for the whole of a mint transition).
    # The shim must not enter the critical section at all.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare_token "$tn" "$SID" "nonceA"
    : > "$(_s_lock_path "$tmp")"
    res=$(run_shim "$tn" "$SID" "$WF_BOUND")
    out="${res#*|}"
    assert_has "S2 held lock => the OFF emit is BLOCKED" '"decision":"block"' "$out"
    assert_has "S2 the reason names the lock, not a missing clearance" "mint lock busy" "$out"
    assert_has "S2 the reason tells the operator it is transient + retryable" "re-emit the same OFF sentinel" "$out"
    assert_eq  "S2 no .claimed was created outside the lock"  "no"  "$(exists_str "$(_s_claim_path "$tmp")")"
    assert_eq  "S2 the bare token SURVIVES (not consumed by a refused claim)" "yes" \
        "$(exists_str "$(_s_bare_path "$tmp")")"
    assert_eq  "S2 the shim did not delete the lock it failed to take" "yes" \
        "$(exists_str "$(_s_lock_path "$tmp")")"

    # ---- S3: recovery. Once the holder releases, the SAME token still works —
    # a lock-busy block must be transient, exactly as its message promises. If
    # the refused attempt had corrupted or consumed anything, this fails.
    rm -f "$(_s_lock_path "$tmp")"
    res=$(run_shim "$tn" "$SID" "$WF_BOUND")
    assert_eq  "S3 after the lock frees, the same token is claimable" "0|" "$res"
    assert_eq  "S3 .claimed created on the retry"                     "yes" "$(exists_str "$(_s_claim_path "$tmp")")"
    assert_eq  "S3 bare token consumed on the retry"                  "no"  "$(exists_str "$(_s_bare_path "$tmp")")"
    rm -rf "$tmp"

    # ---- S4a: POST-LOCK RE-READ, allow direction.
    # Timeline forced here == the real race: the shim reads generation A, then a
    # "mint" (this test) replaces the bare token with generation B while the shim
    # is still waiting on the lock. What lands in `.claimed` must be B — the
    # generation that is actually on disk when the claim happens. A pre-lock-read
    # shim would write A's nonce (and unlink B without ever honouring it).
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare_token "$tn" "$SID" "nonceA"
    # Generation B is prepared BEFORE the window opens and swapped in with a
    # plain copy: the shim's lock budget is 1000ms, and spawning node inside the
    # window (as minting B in place would) could eat most of it and turn this
    # into a lock-busy flake instead of the race it is meant to reproduce.
    cp "$(_s_bare_path "$tmp")" "$tmp/genA.json"
    write_bare_token "$tn" "$SID" "nonceB"
    cp "$(_s_bare_path "$tmp")" "$tmp/genB.json"
    cp "$tmp/genA.json" "$(_s_bare_path "$tmp")"
    : > "$(_s_lock_path "$tmp")"
    ( res=$(run_shim "$tn" "$SID" "$WF_BOUND"); printf '%s' "$res" > "$tmp/s4a.out" ) &
    local shim_pid=$!
    sleep 0.25
    cp "$tmp/genB.json" "$(_s_bare_path "$tmp")"
    rm -f "$(_s_lock_path "$tmp")"
    wait "$shim_pid" 2>/dev/null
    res=$(cat "$tmp/s4a.out" 2>/dev/null)
    assert_eq  "S4a swapped-under-lock token is still allowed"  "0|" "$res"
    assert_eq  "S4a .claimed records the POST-lock generation"  "nonceB" \
        "$(read_json_field "$(_s_claim_path "$tmp")" mint_nonce)"
    assert_eq  "S4a the post-lock bare token was the one consumed" "no" \
        "$(exists_str "$(_s_bare_path "$tmp")")"
    rm -rf "$tmp"

    # ---- S4b: POST-LOCK RE-READ, deny direction (CPR-ORTH — the mirror of S4a).
    # Same timeline, but generation B is EXPIRED. A shim that validated its
    # pre-lock read of the still-valid A would claim an expired grant. The
    # verdict must follow the bytes that are on disk inside the lock.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare_token "$tn" "$SID" "nonceB" "-5"   # expired 5 minutes ago
    cp "$(_s_bare_path "$tmp")" "$tmp/genExpired.json"
    write_bare_token "$tn" "$SID" "nonceA"        # the valid generation the shim reads first
    : > "$(_s_lock_path "$tmp")"
    ( res=$(run_shim "$tn" "$SID" "$WF_BOUND"); printf '%s' "$res" > "$tmp/s4b.out" ) &
    shim_pid=$!
    sleep 0.25
    cp "$tmp/genExpired.json" "$(_s_bare_path "$tmp")"
    rm -f "$(_s_lock_path "$tmp")"
    wait "$shim_pid" 2>/dev/null
    res=$(cat "$tmp/s4b.out" 2>/dev/null)
    assert_has "S4b an expired post-lock generation BLOCKS" '"decision":"block"' "${res#*|}"
    assert_eq  "S4b no .claimed for an expired generation"   "no" "$(exists_str "$(_s_claim_path "$tmp")")"
    assert_not_has "S4b the block is about clearance, not the lock" "mint lock busy" "${res#*|}"
    rm -rf "$tmp"

    # ---- S5: BOUNDARY. lock-busy must not become a catch-all. With no lock at
    # all and a reason whose category does not match the token, the block must
    # come from the reason binding.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_bare_token "$tn" "$SID" "nonceA"
    res=$(run_shim "$tn" "$SID" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [convenience] I would rather not>>"')
    assert_has "S5 category-mismatched reason is blocked"       '"decision":"block"' "${res#*|}"
    assert_not_has "S5 and NOT reported as a lock problem"      "mint lock busy" "${res#*|}"
    assert_eq  "S5 no .claimed for a rejected reason binding"   "no" "$(exists_str "$(_s_claim_path "$tmp")")"
    assert_eq  "S5 lock left free after a validation failure"   "no" "$(exists_str "$(_s_lock_path "$tmp")")"
    rm -rf "$tmp"
}
