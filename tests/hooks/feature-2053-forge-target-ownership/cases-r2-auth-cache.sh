#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Round-2 C7 — the cache belongs to an AUTH CONTEXT, table-driven over all of it.
#
# WHY: I-6 in cases-g-i.sh proves a changed GH_TOKEN invalidates the cached
# ownership answer; it is only one of six variables deciding WHO gh
# authenticates as and WHICH host it talks to, and any of the other five
# changing mid-session leaves the same hazard on disk. GH_HOST is sharpest:
# ownership on github.com says nothing about an enterprise host.

run_block_r2_auth_cache() {
    echo ""
    echo "=== R2-C7-1: every auth-context variable invalidates a cached proof ==="

    local OWNED_C1="gh issue create --repo $OWNER/agents --title x"
    local OWNED_C2="gh issue create --repo $OWNER/agents --title y"
    local name change

    # Row shape: <name>|<VAR=value applied on the SECOND call only>.
    # The first call is unarmed and must prove ownership with exactly one login
    # probe. The second call changes the auth context and must NOT reuse that
    # proof — proven by a fresh login probe, not by the verdict alone (a guard
    # that asks would also change the verdict while still trusting the cache).
    while IFS='|' read -r name change; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$OWNED_C1"
        assert_probes "R2-C7-1 [$name] the first call proves ownership once" "api user" 1
        CASE_ENV=("$change")
        resume_case "$FX_OWNED" "$OWNED_C2"
        assert_probes "R2-C7-1 [$name] the changed context forces a re-probe" "api user" 1
        assert_eq "R2-C7-1 [$name] and the hook still exits 0" "0" "$HOOK_RC"
    done <<TABLE
GH_TOKEN|GH_TOKEN=r2-token-alpha
GITHUB_TOKEN|GITHUB_TOKEN=r2-token-bravo
GH_ENTERPRISE_TOKEN|GH_ENTERPRISE_TOKEN=r2-token-charlie
GITHUB_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN=r2-token-delta
GH_CONFIG_DIR|GH_CONFIG_DIR=$BASE/other-gh-config
GH_HOST|GH_HOST=ghe.example.com
TABLE

    echo ""
    echo "=== R2-C7-2: a changed context cannot silently authorize a foreign target ==="

    # The verdict half of the same table. The first call proves the OWNED target;
    # the second call, under a new identity, names a FOREIGN one. A cache keyed on
    # the session rather than on the auth context turns this into a silent allow.
    while IFS='|' read -r name change; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$OWNED_C1"
        assert_decision "R2-C7-2 [$name] the owned baseline is silent" "silent"
        CASE_ENV=("$change" "GH_STUB_EXIT=1")
        resume_case "$FX_OWNED" "gh issue create --repo $FOREIGN/r --title x"
        assert_decision "R2-C7-2 [$name] new identity + foreign target -> ask" "ask"
    done <<TABLE
GH_TOKEN|GH_TOKEN=r2-token-alpha
GITHUB_TOKEN|GITHUB_TOKEN=r2-token-bravo
GH_ENTERPRISE_TOKEN|GH_ENTERPRISE_TOKEN=r2-token-charlie
GITHUB_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN=r2-token-delta
GH_CONFIG_DIR|GH_CONFIG_DIR=$BASE/other-gh-config
GH_HOST|GH_HOST=ghe.example.com
TABLE

    echo ""
    echo "=== R2-C7-3: none of those values is persisted anywhere ==="

    # Whatever fingerprint the guard stores, it must not store the SECRET. A
    # cache file holding the literal token turns the state dir into a credential
    # store readable by anything running as the user (OWASP ASVS V8). The values
    # above are distinctive strings precisely so this sweep can find them.
    local leaked="" v
    for v in r2-token-alpha r2-token-bravo r2-token-charlie r2-token-delta; do
        if grep -rqF -- "$v" "$CLAUDE_WORKFLOW_DIR" 2>/dev/null; then leaked="$leaked $v"; fi
        if grep -rqF -- "$v" "$WORKFLOW_PLANS_DIR" 2>/dev/null; then leaked="$leaked $v(plans)"; fi
    done
    assert_eq "R2-C7-3a no token value was written into the state or plans dir" "" "$leaked"
    # The reason text is user-visible; a fingerprint echoed there is the same leak
    # by a shorter route.
    reset_env
    run_case "$FX_OWNED" "$OWNED_C1"
    CASE_ENV=("GH_TOKEN=r2-token-echo")
    resume_case "$FX_OWNED" "gh issue create --repo $FOREIGN/r --title x"
    assert_reason_lacks "r2-token-echo" "R2-C7-3b the reason names the change, never the value"

    echo ""
    echo "=== R2-C7-4: the control — an UNCHANGED context still reuses the proof ==="

    # Round-2 C7 is only a real finding if the cache exists at all. If every call
    # re-probed unconditionally, every row above would pass while the guard was
    # simply doing no caching — a different defect wearing the same green.
    reset_env
    run_case "$FX_OWNED" "$OWNED_C1"
    assert_probes "R2-C7-4a first call probes the login once" "api user" 1
    resume_case "$FX_OWNED" "$OWNED_C2"
    assert_probes "R2-C7-4b an unchanged context reuses it (no re-probe)" "api user" 0
    assert_decision "R2-C7-4c and the verdict is still a silent allow" "silent"
}
