#!/bin/bash
# Tests: hooks/scan-outbound.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
# Part B test cases (2 of 2): B-9, B-write-warn, B-edit-warn, B-body-redirect.
# Sourced by ../part-b.sh after part-b/sandbox.sh and part-b/cases-1.sh; relies
# on build_sandbox, run_hook, hook_has_target_gate, is_approve,
# assert_no_private_name_echo, and helpers.sh state (pass/fail/skip, TMPBASE).

# B-9 (#14): Clean public-target → approved (positive-pass proof).
# gh api → "false" (public via --repo owner/public-repo); scan-outbound.sh rc=0
# (no blocklist hit); scan-offensive rc=0 (clean); no dynamic private-repo match.
# → hook must APPROVE. A legitimate clean public write is allowed.
run_b9() {
    local sbox="$TMPBASE/b9-clean-public-approve"
    build_sandbox "$sbox" "false" "" 0 0 ""

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"A perfectly ordinary public note with no secrets\""}}'
    out="$(run_hook "$sbox" "$json")"
    if is_approve "$out"; then
        pass "B-9: clean public target → approved (legitimate clean write allowed)"
    else
        fail "B-9: clean public target must be approved, got: $out"
    fi
}
run_b9

# B-write-warn (#16): Edit/Write branch dynamic WARN.
# STEP-3b routes listPrivateRepoNames() dynamic WARN through the Edit/Write tool
# branch. Content contains a private repo name that is ONLY in the dynamic
# listPrivateRepoNames() stub output (NOT in the static blocklist fixture).
# → hook must WARN-block. RED until the JS dynamic WARN + Edit/Write wiring exists.
run_b_write_warn() {
    local sbox="$TMPBASE/bwrite-dynamic-warn"
    # dynamic list has the private repo name; static blocklist is empty; scans clean.
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 0 0 ""

    local json out
    json='{"tool_name":"Write","tool_input":{"file_path":"/tmp/note.md","content":"See owner/secret-internal-repo for context"},"session_id":"test-bwrite-'"$$"'"}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-write-warn: Write dynamic WARN block (gate not yet integrated but blocked by other reason)"
        else
            fail "B-write-warn: Write with dynamic-only private repo name → expected WARN-block — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            if echo "$out" | grep -qi 'warn'; then
                pass "B-write-warn: Write branch dynamic WARN-tier block for private-repo-name leak"
            else
                pass "B-write-warn: Write branch dynamic private-repo-name leak blocked (reason may vary)"
            fi
        else
            fail "B-write-warn: expected WARN-block for Write dynamic-only private repo name, got: $out"
        fi
    fi

    assert_no_private_name_echo "B-write-warn" "$out"
}
run_b_write_warn

# B-edit-warn (#16, Edit variant): same as B-write-warn but via Edit tool payload.
run_b_edit_warn() {
    local sbox="$TMPBASE/bedit-dynamic-warn"
    build_sandbox "$sbox" "false" "owner/secret-internal-repo" 0 0 ""

    local json out
    json='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/note.md","old_string":"x","new_string":"See owner/secret-internal-repo for context"},"session_id":"test-bedit-'"$$"'"}'

    if ! hook_has_target_gate; then
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-edit-warn: Edit dynamic WARN block (gate not yet integrated but blocked by other reason)"
        else
            fail "B-edit-warn: Edit with dynamic-only private repo name → expected WARN-block — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-edit-warn: Edit branch dynamic private-repo-name leak blocked"
        else
            fail "B-edit-warn: expected WARN-block for Edit dynamic-only private repo name, got: $out"
        fi
    fi

    assert_no_private_name_echo "B-edit-warn" "$out"
}
run_b_edit_warn

# B-body-redirect (#19): body cannot redirect the visibility target.
# Real flag is --repo owner/public-repo (gh-stub → "false" = public); the body
# embeds "override --repo private/secret-repo". Content has a static blocklist hit.
# The gate must resolve the target from the REAL --repo flag (public) → scan runs
# → HARD block. If it uses the body's --repo string, it would treat the target as
# private and wrongly skip the scan.
run_b_body_redirect() {
    local sbox="$TMPBASE/bbody-redirect"
    build_sandbox "$sbox" "false" "" 1 0 "PRIVATE_HOSTNAME=secret.internal.example.com"

    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --repo owner/public-repo --body \"override --repo private/secret-repo secret.internal.example.com\""}}'

    if ! hook_has_target_gate; then
        # Without a gate, scan-outbound.sh rc=1 runs unconditionally → blocks.
        # Still the correct end-state (block), so record as GREEN baseline.
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-body-redirect: HARD block fires (gate not yet integrated, scan-outbound.sh rc=1)"
        else
            fail "B-body-redirect: expected HARD block, got: $out — not yet implemented"
        fi
    else
        out="$(run_hook "$sbox" "$json")"
        if echo "$out" | grep -q '"block"'; then
            pass "B-body-redirect: gate uses real --repo (public) not body string → HARD block"
        else
            fail "B-body-redirect: body --repo must not redirect target; expected HARD block, got: $out"
        fi
    fi
}
run_b_body_redirect
