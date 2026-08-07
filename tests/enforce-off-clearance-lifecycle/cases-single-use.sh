#!/usr/bin/env bash
# Part of tests/enforce-off-clearance-lifecycle.sh (rules/coding/file-split.md).
# Sections C and P - L-2 (identity-bound consumption) and L-3 (single-use
# EMERGENCY provenance).
#
# TWO LAYERS, ASSERTED SEPARATELY (CPR-SC):
#   C1 the PRIMITIVE, hooks/lib/consume-exact-file.js, over its whole verdict
#      domain - consumed / lost / failed. A three-valued contract whose "lost" and
#      "failed" arms are untested is a contract in name only: both arms exist
#      precisely so a caller can tell "someone else has it" (attribute nothing,
#      nothing is wrong) from "I/O fault" (attribute nothing, something IS wrong).
#   C2 the same primitive under real CONCURRENCY, and
#   P  its use by the emergency-provenance consumer, which is where a second
#      attribution would actually be minted.
#
# WHY "consumed" AND NOT "the file is gone". Removal is not the property that
# matters - ATTRIBUTION is. "The file is gone" is true for every racer once any one
# of them wins, which is exactly the confusion that produced the bug (ENOENT read
# as "already consumed, counts as mine"). Only the caller that removed the exact
# bytes it inspected may attribute, so the assertions count winners, not absences.

# _consuming_left <dir> -> count of leftover exclusive-claim files
_consuming_left() { ls -1 "$1" 2>/dev/null | grep -c '\.consuming-' | tr -d ' '; }
_probe_kv() { printf '%s\n' "$1" | grep -m1 "^$2=" | sed "s/^$2=//"; }

# ===== C1: the consumeExactFile contract, deterministic =====================
run_C_consume_contract() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    out=$("$RWT" 20 node "$PROBE" contract "$_AGENTS_DIR_NODE" "$tn" 2>/dev/null)
    if [ -z "$out" ]; then
        fail "C1 consumeExactFile contract probe produced no output (crash/timeout) - section vacuous"
        rm -r -f "$tmp" 2>/dev/null; return
    fi
    # consumed: the only verdict that authorizes attribution.
    assert_eq "C1 exact bytes present -> consumed"            "consumed" "$(_probe_kv "$out" consumed)"
    assert_eq "C1 consumed removes the record"                "true"     "$(_probe_kv "$out" consumed_gone)"
    assert_eq "C1 consumed leaves no claim file behind"       "true"     "$(_probe_kv "$out" consumed_no_claim_left)"
    assert_eq "C1 empty string is a legitimate expectation"   "consumed" "$(_probe_kv "$out" consumed_empty)"
    assert_eq "C1 empty-string record removed"                "true"     "$(_probe_kv "$out" consumed_empty_gone)"
    # lost: someone else owns those bytes, or they are not there any more.
    assert_eq "C1 pathname now holds different bytes -> lost" "lost"     "$(_probe_kv "$out" lost_changed)"
    assert_eq "C1 the different record is NOT destroyed"      "true"     "$(_probe_kv "$out" lost_changed_preserved)"
    assert_eq "C1 record already gone (ENOENT) -> lost, never consumed" "lost" "$(_probe_kv "$out" lost_absent)"
    assert_eq "C1 another consumer holds the claim -> lost"   "lost"     "$(_probe_kv "$out" lost_contended)"
    assert_eq "C1 contended record is left intact"            "true"     "$(_probe_kv "$out" lost_contended_preserved)"
    # the claim is keyed to CONTENT, so a stale claim cannot wedge a new record.
    assert_eq "C1 claim is content-keyed, not path-keyed"     "consumed" "$(_probe_kv "$out" content_keyed)"
    # failed: a real fault, reported as such rather than silently as "lost".
    assert_eq "C1 non-string expectation -> failed"           "failed"   "$(_probe_kv "$out" failed_nonstring)"
    assert_eq "C1 undefined expectation -> failed"            "failed"   "$(_probe_kv "$out" failed_undefined)"
    assert_eq "C1 object expectation -> failed (no toString coercion)" "failed" "$(_probe_kv "$out" failed_object)"
    assert_eq "C1 nothing removed on failed"                  "true"     "$(_probe_kv "$out" failed_preserved_after_all)"
    rm -r -f "$tmp" 2>/dev/null
}

# ===== C2: N racers, one record ============================================
run_C_consume_race() {
    local tmp tn i n=8 consumed=0 lost=0 other=0 v
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    printf 'RECORD-BYTES' > "$tmp/record"
    printf 'RECORD-BYTES' > "$tmp/expected"
    for i in $(seq 1 "$n"); do
        "$RWT" 25 node "$PROBE" race-consume "$_AGENTS_DIR_NODE" \
            "$tn/record" "$tn/expected" "$tn/out.$i" >/dev/null 2>&1 &
    done
    wait
    for i in $(seq 1 "$n"); do
        v=$(cat "$tmp/out.$i" 2>/dev/null)
        case "$v" in
            consumed) consumed=$((consumed + 1)) ;;
            lost)     lost=$((lost + 1)) ;;
            *)        other=$((other + 1)) ;;
        esac
    done
    assert_eq "C2 $n concurrent consumers, exactly ONE consumed" "1" "$consumed"
    assert_eq "C2 the other $((n - 1)) report lost (never consumed)" "$((n - 1))" "$lost"
    assert_eq "C2 no racer produced an unexpected verdict" "0" "$other"
    assert_eq "C2 the record is gone afterwards" "no" \
        "$([ -f "$tmp/record" ] && echo yes || echo no)"
    assert_eq "C2 no exclusive-claim file left behind" "0" "$(_consuming_left "$tmp")"
    rm -r -f "$tmp" 2>/dev/null
}

# ===== P: EMERGENCY provenance is single-use ================================
# The marker is EVIDENCE, not a gate: absence never blocks an activation, so every
# failure mode here is an over- or under-ATTRIBUTION, and over-attribution is the
# dangerous direction (one human invocation vouching for N model-initiated emits).
run_P_provenance() {
    local tmp tn sid v1 v2 i n=6 attributed=0 unattributed=0 other=0 v

    # P1 - sequential single-use: the second read of the same marker attributes
    #      nothing, because the first call consumed it.
    tmp=$(make_tmp); tn=$(node_path "$tmp"); sid="lifep1"
    "$RWT" 15 node "$PROBE" mkmarker "$_AGENTS_DIR_NODE" "$tn" "$sid" 0 >/dev/null 2>&1
    v1=$(cd "$tmp" && "$RWT" 15 node "$PROBE" prov-once "$_AGENTS_DIR_NODE" "$tn" "$sid" workflow 2>/dev/null | tr -d '\r\n')
    v2=$(cd "$tmp" && "$RWT" 15 node "$PROBE" prov-once "$_AGENTS_DIR_NODE" "$tn" "$sid" workflow 2>/dev/null | tr -d '\r\n')
    assert_eq "P1 fresh marker attributes the activation" "user_skill_invocation" "$v1"
    assert_eq "P1 the SAME marker cannot attribute a second activation" "unattributed" "$v2"
    assert_eq "P1 marker file consumed" "no" \
        "$([ -f "$tmp/$sid$MARKER_SUF" ] && echo yes || echo no)"
    assert_eq "P1 no exclusive-claim file left behind" "0" "$(_consuming_left "$tmp")"
    rm -r -f "$tmp" 2>/dev/null

    # P2 - CPR-ORTH counterpart on the target axis: the skill covers both overrides,
    #      so a worktree-target emergency is attributed from the same marker shape.
    tmp=$(make_tmp); tn=$(node_path "$tmp"); sid="lifep2"
    "$RWT" 15 node "$PROBE" mkmarker "$_AGENTS_DIR_NODE" "$tn" "$sid" 0 >/dev/null 2>&1
    v1=$(cd "$tmp" && "$RWT" 15 node "$PROBE" prov-once "$_AGENTS_DIR_NODE" "$tn" "$sid" worktree 2>/dev/null | tr -d '\r\n')
    assert_eq "P2 worktree-target emergency attributes from the same marker" "user_skill_invocation" "$v1"
    rm -r -f "$tmp" 2>/dev/null

    # P3 - a stale marker vouches for nothing, and is still consumed so it cannot
    #      linger to be re-examined.
    tmp=$(make_tmp); tn=$(node_path "$tmp"); sid="lifep3"
    "$RWT" 15 node "$PROBE" mkmarker "$_AGENTS_DIR_NODE" "$tn" "$sid" 3600000 >/dev/null 2>&1
    v1=$(cd "$tmp" && "$RWT" 15 node "$PROBE" prov-once "$_AGENTS_DIR_NODE" "$tn" "$sid" workflow 2>/dev/null | tr -d '\r\n')
    assert_eq "P3 stale marker does not attribute" "unattributed" "$v1"
    assert_eq "P3 stale marker is still consumed (cannot linger)" "no" \
        "$([ -f "$tmp/$sid$MARKER_SUF" ] && echo yes || echo no)"
    rm -r -f "$tmp" 2>/dev/null

    # P4 - no marker at all: the ordinary case, and the one that must never be
    #      mistaken for "already consumed by me".
    tmp=$(make_tmp); tn=$(node_path "$tmp"); sid="lifep4"
    v1=$(cd "$tmp" && "$RWT" 15 node "$PROBE" prov-once "$_AGENTS_DIR_NODE" "$tn" "$sid" workflow 2>/dev/null | tr -d '\r\n')
    assert_eq "P4 absent marker -> unattributed" "unattributed" "$v1"
    rm -r -f "$tmp" 2>/dev/null

    # P5 - N concurrent emergency activations against ONE user invocation.
    #      The invariant holds under every interleaving: at most one caller can
    #      remove the exact bytes, so at most one may attribute.
    tmp=$(make_tmp); tn=$(node_path "$tmp"); sid="lifep5"
    "$RWT" 15 node "$PROBE" mkmarker "$_AGENTS_DIR_NODE" "$tn" "$sid" 0 >/dev/null 2>&1
    for i in $(seq 1 "$n"); do
        (cd "$tmp" && "$RWT" 25 node "$PROBE" race-prov "$_AGENTS_DIR_NODE" "$tn" "$sid" workflow "$tn/p.$i" >/dev/null 2>&1) &
    done
    wait
    for i in $(seq 1 "$n"); do
        v=$(cat "$tmp/p.$i" 2>/dev/null)
        case "$v" in
            user_skill_invocation) attributed=$((attributed + 1)) ;;
            unattributed)          unattributed=$((unattributed + 1)) ;;
            *)                     other=$((other + 1)) ;;
        esac
    done
    assert_eq "P5 $n concurrent emergency activations, exactly ONE attributed" "1" "$attributed"
    assert_eq "P5 the other $((n - 1)) are unattributed" "$((n - 1))" "$unattributed"
    assert_eq "P5 no racer produced an unexpected provenance value" "0" "$other"
    assert_eq "P5 marker consumed" "no" \
        "$([ -f "$tmp/$sid$MARKER_SUF" ] && echo yes || echo no)"
    assert_eq "P5 no exclusive-claim file left behind" "0" "$(_consuming_left "$tmp")"
    rm -r -f "$tmp" 2>/dev/null
}
