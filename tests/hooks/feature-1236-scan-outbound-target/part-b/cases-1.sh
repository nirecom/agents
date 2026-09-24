#!/bin/bash
# Tests: hooks/scan-outbound.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
# Part B test cases (1 of 2): B-1 .. B-6, B-8.
# Sourced by ../part-b.sh after part-b/sandbox.sh; relies on build_sandbox,
# run_hook, hook_has_target_gate, is_approve, assert_no_private_name_echo,
# and helpers.sh state (pass/fail/skip, TMPBASE).

# ── Tests ────────────────────────────────────────────────────────────────────

# B-1: Public target + static-blocklisted content → HARD block (core attack scenario)
run_b1() {
    local sbox="$TMPBASE/b1-pub-hard"
    build_sandbox "$sbox" "false" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"See secret.internal.example.com for details\""}}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-1: public-target HARD block (static blocklist) — gate not yet integrated but scan-outbound.sh rc=1 blocks"
        else
            fail "B-1: expected block (static blocklist), got: $out — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-1: public-target + static-blocklisted content → HARD block"
        else
            fail "B-1: expected HARD block for public target with blocklisted content, got: $out"
        fi
    fi
}
run_b1

# B-2: Public target + dynamic-only private repo name → WARN-tier block
run_b2() {
    local sbox="$TMPBASE/b2-pub-warn"
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 0 0 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"See owner/secret-internal-repo for context\""}}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-2: dynamic WARN block (gate not yet integrated but blocked by other reason)"
        else
            fail "B-2: public-target + dynamic private repo name → expected WARN-tier block — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            if echo "$out" | grep -qi 'warn'; then
                pass "B-2: dynamic WARN-tier block for private-repo-name leak to public target"
            else
                pass "B-2: dynamic private-repo-name leak blocked (reason may vary)"
            fi
        else
            fail "B-2: expected WARN-tier block for dynamic-only private repo name leak, got: $out"
        fi
    fi

    assert_no_private_name_echo "B-2" "$out"
}
run_b2

# B-3: HARD-before-WARN precedence — both static+dynamic match → HARD reason dominates
run_b3() {
    local sbox="$TMPBASE/b3-precedence"
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"Contact secret.internal.example.com or see owner/secret-internal-repo\""}}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-3: HARD block fires (gate not yet integrated, blocked by scan-outbound.sh rc=1)"
        else
            fail "B-3: expected HARD block, got: $out — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            if echo "$out" | grep -qi 'warn-only\|warn only'; then
                fail "B-3: HARD-before-WARN violated — got warn-only reason instead of HARD: $out"
            else
                pass "B-3: HARD-before-WARN precedence — HARD reason returned (not warn-only)"
            fi
        else
            fail "B-3: expected HARD block for combined static+dynamic match, got: $out"
        fi
    fi
}
run_b3

# B-4: Private target + offensive content → offensive scanner STILL blocks
run_b4() {
    local sbox="$TMPBASE/b4-private-target-offensive"
    build_sandbox "$sbox" "true" "" 0 1 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/private-repo --body \"offensive content that should always be caught\""}}'
    out="$(run_hook "$sbox" "$json")"
    if echo "$out" | grep -q '"block"'; then
        pass "B-4: private target + offensive content → offensive scanner blocks (private skip does not exempt offensive)"
    else
        fail "B-4: offensive scanner must run even for private targets — got: $out"
    fi
}
run_b4

# B-4b (#15): Private target bypasses the private-info scan.
# scan-outbound.sh WOULD HARD-block (rc=1) if it ran, but the target is private
# so the visibility gate must SKIP the private-info scan. Offensive is clean (rc=0).
# → hook must APPROVE. If it blocks here, the private-info scan wrongly ran.
run_b4b() {
    local sbox="$TMPBASE/b4b-private-skips-privinfo"
    # gh api → "true" (private); scan-outbound.sh rc=1 (would HARD-block if run);
    # scan-offensive rc=0 (clean).
    build_sandbox "$sbox" "true" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/private-repo --body \"See secret.internal.example.com for details\""}}'

    if ! hook_has_target_gate; then
        # Pre-fix vulnerable state: no gate → scan-outbound.sh rc=1 runs unconditionally → blocks.
        # This is the RED proof that the private-info scan is NOT yet skipped for private targets.
        out="$(run_hook "$sbox" "$json")"
        if is_approve "$out"; then
            fail "B-4b: private target unexpectedly approved before gate exists — check sandbox"
        else
            fail "B-4b: private target still runs private-info scan (blocks) — visibility gate not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if is_approve "$out"; then
            pass "B-4b: private target → private-info scan SKIPPED → approve (offensive clean)"
        else
            fail "B-4b: private target must skip private-info scan and approve, got block: $out"
        fi
    fi
}
run_b4b

# B-5: gh api error (stub exits non-zero) → shouldScanAsPublicTarget fail-closed → still HARD-blocks
run_b5() {
    local sbox="$TMPBASE/b5-gh-api-err"
    build_sandbox "$sbox" "" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"
    cat > "$sbox/bin/gh-stub/gh" <<'GHSTUB'
#!/bin/bash
if [[ "$1" == "api" ]]; then
    exit 1
fi
exit 0
GHSTUB
    chmod +x "$sbox/bin/gh-stub/gh"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/maybe-public --body \"See secret.internal.example.com\""}}'
    out="$(run_hook "$sbox" "$json")"
    if echo "$out" | grep -q '"block"'; then
        pass "B-5: gh api error → fail-closed → scan runs → HARD block"
    else
        fail "B-5: expected HARD block when gh api fails (fail-closed), got: $out"
    fi
}
run_b5

# B-6: Short -R flag behaves same as --repo for public-target HARD case
run_b6() {
    local sbox="$TMPBASE/b6-short-flag"
    build_sandbox "$sbox" "false" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create -R owner/public-repo --body \"See secret.internal.example.com\""}}'
    out="$(run_hook "$sbox" "$json")"
    if echo "$out" | grep -q '"block"'; then
        pass "B-6: -R short flag → same as --repo → public-target HARD block"
    else
        fail "B-6: expected HARD block with -R short flag, got: $out — not yet implemented"
    fi
}
run_b6

# SKIPPED: B-7 no-flag cwd-based target resolution (L2-fragile; see dispatcher L3 gap).

# B-8: Bare #N in body (no owner/repo prefix) → approve (not flagged as private-repo-name)
run_b8() {
    local sbox="$TMPBASE/b8-bare-hash"
    build_sandbox "$sbox" "false" "" 0 0 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"see #123 for context\""}}'
    out="$(run_hook "$sbox" "$json")"
    if is_approve "$out"; then
        pass "B-8: bare #N in body → approved (bare issue ref not flagged)"
    else
        fail "B-8: bare #N in body should be approved, got: $out"
    fi
}
run_b8
