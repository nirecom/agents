#!/usr/bin/env bash
# Tests: hooks/lib/forge-write-extract.js
# Tags: hook, forge, glab, gitlab, scan-target, scope:issue-specific, TL1
# Part of tests/feature-forge-write-scan-extract.sh (rules/coding/file-split.md).
# Section 2307 — glab forge-write scan targeting. TEST-FIRST / INTENDED RED:
# #2307 makes glab writes scan targets (security invariant; GitLab op = #2308).
# E1/E2/E5 RED->GREEN after impl; E3 gh regression GREEN; E4 read-only false.

# expect_scan_chain: the outbound-scan chain — isForgeScanTarget(cmd) true AND
# extractTexts(cmd) surfaces <needle>. extractTexts is already generic over
# --description, so today only recognition fails (the #2307 gap; intended RED).
expect_scan_chain() {
    local desc="$1" cmd="$2" needle="$3"
    local tgt ext
    tgt="$(call_driver target "$cmd")"
    ext="$(call_driver extract "$cmd")"
    if echo "$tgt" | grep -q '"missing":true'; then
        fail "$desc — forge-write-extract.js not yet implemented"
        return
    fi
    if echo "$tgt" | grep -q '"value":true' && echo "$ext" | grep -q "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected scan-target=true AND extracted secret; target=$tgt extract=$ext"
    fi
}

run_2307_glab() {
    echo ""
    echo "=== 2307: glab forge-write scan targeting (test-first, intended RED) ==="

    # E1/E2: #2307 makes glab mr/issue writes scan targets. RED today, GREEN after.
    expect_target_true "E1 glab mr create -> true (#2307 target; intended RED)" \
        'glab mr create --title "T" --description "D"'
    expect_target_true "E2 glab issue create -> true (#2307 target; intended RED)" \
        'glab issue create --title "T" --description "D"'

    # E3 regression guard: gh writes must stay scan targets (GREEN today and after).
    expect_target_true "E3 gh pr create -> true (regression)" \
        'gh pr create --body "B"'

    # E4 negative control: glab status is read-only, false now AND after #2307.
    expect_target_false "E4 glab status -> false (read-only)" \
        'glab status'

    # E5 security integration (reviewer C2): recognized-as-target -> extracted ->
    # scannable. RED today (glab not a target), GREEN once #2307 recognizes it.
    expect_scan_chain "E5 glab issue create --description -> recognized + extracted (#2307 target; intended RED)" \
        'glab issue create --title "T" --description "forge-scan-canary-2307"' \
        'forge-scan-canary-2307'
}
