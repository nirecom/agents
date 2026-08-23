#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Round-2 C8 — HOSTILE SUCCESSFUL probe responses (exit 0, unusable body).
#
# WHY: the remaining hole after every FAIL case is a probe that SUCCEEDS with
# something unreadable — JS truthiness where "" is falsy but "false" is truthy
# and a missing `permissions` throws. `if (repo.permissions.admin)` allows on
# "false" and crashes on a missing field, both wrong like #2053. Contract:
# only an unambiguous, correctly-typed YES is not an ask.

run_block_r2_probe_responses() {
    echo ""
    echo '=== R2-C8-1: `gh api user` succeeds but the login is unusable ==='

    # The target is the OWNED repo throughout: with a healthy probe this is a
    # silent allow (see C6-4a), so any ask here is caused by the response body
    # alone. GH_STUB_LOGIN is bypassed by GH_STUB_USER_RAW, which writes the body
    # verbatim and still exits 0.
    local name body
    while IFS='|' read -r name body; do
        [ -z "$name" ] && continue
        case "$body" in "@EMPTY") body="" ;; "@SPACE") body="   " ;; "@NL") body=$'\n' ;; esac
        reset_env
        CASE_ENV=("GH_STUB_USER_RAW=$body" "GH_STUB_ADMIN=false")
        run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
        assert_decision "R2-C8-1 [$name] unusable login -> ask" "ask"
        assert_eq "R2-C8-1 [$name] and the hook still exits 0" "0" "$HOOK_RC"
    done <<TABLE
empty body|@EMPTY
whitespace only|@SPACE
newline only|@NL
literal null|null
literal undefined|undefined
json null|{"login":null}
json object where text was expected|{"login":"$OWNER"}
error payload with 200|{"message":"Not Found"}
html error page|<html><body>502</body></html>
truncated json|{"login":"testown
boolean instead of a login|true
number instead of a login|12345
array instead of a login|["$OWNER"]
login with an embedded newline|$OWNER\nattacker
TABLE

    echo ""
    echo "=== R2-C8-2: the capability probe succeeds but proves nothing ==="

    # The capability rung is reached when the login does NOT match (I-1/I-2), so
    # the login is forced to a different user and the whole verdict then rests on
    # this body. Every row must ask; only a real boolean true may allow.
    while IFS='|' read -r name body; do
        [ -z "$name" ] && continue
        case "$body" in "@EMPTY") body="" ;; esac
        reset_env
        CASE_ENV=("GH_STUB_LOGIN=someoneelse-r2" "GH_STUB_REPO_RAW=$body")
        run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
        assert_decision "R2-C8-2 [$name] -> ask" "ask"
        assert_eq "R2-C8-2 [$name] and the hook still exits 0" "0" "$HOOK_RC"
    done <<TABLE
empty body|@EMPTY
permissions key missing entirely|{"fork":false}
permissions is null|{"permissions":null}
permissions is a string|{"permissions":"admin"}
admin is null|{"permissions":{"admin":null}}
admin is 0|{"permissions":{"admin":0}}
admin is the string false|{"permissions":{"admin":"false"}}
admin is the string true|{"permissions":{"admin":"true"}}
admin is the string 0|{"permissions":{"admin":"0"}}
admin is an empty string|{"permissions":{"admin":""}}
admin is an empty object|{"permissions":{"admin":{}}}
admin is an empty array|{"permissions":{"admin":[]}}
admin key missing|{"permissions":{"push":true}}
push true but not admin|{"permissions":{"push":true,"admin":false}}
not json at all|<html>403</html>
json array at the root|[{"permissions":{"admin":true}}]
TABLE

    echo ""
    echo "=== R2-C8-3: the two rows that MUST still allow ==="

    # Without these the whole block passes on a guard that asks unconditionally.
    # A real boolean true on the capability rung, and an exact login match on the
    # rung above it, are the only two shapes the guard is allowed to accept.
    reset_env
    CASE_ENV=("GH_STUB_LOGIN=someoneelse-r2" "GH_STUB_REPO_RAW={\"permissions\":{\"admin\":true}}")
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "R2-C8-3a a real boolean admin:true -> silent allow" "silent"
    reset_env
    CASE_ENV=("GH_STUB_USER_RAW=$OWNER")
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "R2-C8-3b an exact plain-text login match -> silent allow" "silent"

    echo ""
    echo "=== R2-C8-4: a hostile body must not become the reason text ==="

    # The bodies above are attacker-controlled in the real world (a compromised
    # or spoofed endpoint). Echoing one into permissionDecisionReason puts raw
    # remote content in front of the operator who is being asked to approve.
    reset_env
    CASE_ENV=("GH_STUB_USER_RAW=<script>r2-c8-payload</script>" "GH_STUB_ADMIN=false")
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "R2-C8-4a a script-shaped login body -> ask" "ask"
    assert_reason_lacks "r2-c8-payload" "R2-C8-4b the remote body is not replayed into the reason"
}
