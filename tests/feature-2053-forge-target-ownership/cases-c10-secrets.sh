#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C10 — secret leakage and command injection.
#
# WHY (leakage): reason text and cache reach the user/disk, and origin URLs and
# inline assignments routinely carry credentials (OWASP ASVS V8). WHY
# (injection): the guard interpolates owner/repo/host values it found into its
# OWN probe commands, so untrusted input inspected becomes input executed if
# any of that reaches a shell (CWE-78).

run_block_c10() {
    echo ""
    echo "=== C10-1: credentials the guard reads must not come back out ==="

    local SECRET="s3cr3t-tl2-canary-tokenvalue"
    local FX_CRED FX_CREDSSH

    # assert_no_leak <id> <needle>: the four places a secret can surface — the
    # user-visible reason, the hook's own stdout/stderr, and anything it wrote
    # into the state dir.
    _no_leak() { # <id> <needle>
        local id="$1" needle="$2" hits=""
        printf '%s' "$REASON" | grep -qF -- "$needle" && hits="reason"
        grep -qF -- "$needle" "$BASE/out.txt" 2>/dev/null && hits="$hits stdout"
        grep -qF -- "$needle" "$BASE/err.txt" 2>/dev/null && hits="$hits stderr"
        if grep -rqF -- "$needle" "$CLAUDE_WORKFLOW_DIR" 2>/dev/null; then hits="$hits state-dir"; fi
        if grep -rqF -- "$needle" "$WORKFLOW_PLANS_DIR" 2>/dev/null; then hits="$hits plans-dir"; fi
        if [ -z "$hits" ]; then pass "$id"; else fail "$id" "secret surfaced in:$hits"; fi
    }

    FX_CRED="$(mkfixture credorigin "https://ghuser:$SECRET@github.com/$FOREIGN/r.git")"
    reset_env
    run_case "$FX_CRED" "gh issue create --title x"
    assert_decision "C10-1a a credential-bearing origin still resolves to ask" "ask"
    _no_leak "C10-1b and the credential never appears anywhere" "$SECRET"
    # The reason must still be USEFUL: naming the repo is the whole point, and a
    # blanket redaction that hides the target too would fail this.
    assert_decision "C10-1c the reason still names the target repo" "ask" "$FOREIGN/r"

    FX_CREDSSH="$(mkfixture credssh "ssh://git:$SECRET@github.com/$FOREIGN/r.git")"
    reset_env
    run_case "$FX_CREDSSH" "gh issue create --title x"
    assert_decision "C10-1d an ssh:// origin with userinfo -> ask" "ask"
    _no_leak "C10-1e and it leaks nothing either" "$SECRET"

    # Inline token assignments: block Q already pins the ASK; this pins that the
    # value the guard read to reach that verdict is not echoed back.
    reset_env
    run_case "$FX_OWNED" "GH_TOKEN=$SECRET gh issue create --repo $OWNER/agents --title x"
    assert_decision "C10-2a inline GH_TOKEN -> ask" "ask" "auth-context-change"
    _no_leak "C10-2b the token value is not in the reason, output, or cache" "$SECRET"
    reset_env
    run_case "$FX_OWNED" "export GITHUB_TOKEN=$SECRET"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C10-2c an exported token then a write -> ask" "ask" "auth-context-change"
    _no_leak "C10-2d and the exported value is not persisted in the cache" "$SECRET"

    echo ""
    echo "=== C10-3: nothing the guard reads may execute ==="

    # Each row carries a sentinel that creates a file IF it is ever evaluated by
    # a shell. Two assertions per row: the verdict is ask, and the sentinel file
    # does not exist. The sentinel is the real test — a guard could reach `ask`
    # while still having run the payload on the way there.
    local name cmd sentinel n=0
    while IFS='|' read -r name cmd; do
        [ -z "$name" ] && continue
        n=$((n + 1))
        sentinel="$BASE/pwned-$n"
        rm -f "$sentinel"
        cmd="${cmd//@SENTINEL@/$sentinel}"
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "C10-3 [$name] -> ask" "ask"
        if [ -e "$sentinel" ]; then
            fail "C10-3 [$name] no sentinel executed" "the guard evaluated its own input: $sentinel exists"
        else
            pass "C10-3 [$name] no sentinel executed"
        fi
    done <<TABLE
substitution in a repo selector|gh issue create --repo "\$(touch @SENTINEL@)/r" --title x
backtick in a repo selector|gh issue create --repo "\`touch @SENTINEL@\`/r" --title x
semicolon in a repo selector|gh issue create --repo "a;touch @SENTINEL@" --title x
pipe in a repo selector|gh issue create --repo "a|touch @SENTINEL@" --title x
newline in a repo selector|gh issue create --repo "a\$'\\n'touch @SENTINEL@" --title x
dot-segment repo selector|gh issue create --repo ../../etc/passwd --title x
dot-segment owner|gh issue create --repo ../$OWNER/agents --title x
dot-segment repo half|gh issue create --repo $OWNER/../../other --title x
absolute path selector|gh issue create --repo /etc/passwd --title x
url-encoded traversal|gh issue create --repo %2e%2e%2f$FOREIGN/r --title x
flag-shaped owner|gh issue create --repo --upload-file/r --title x
substitution in GH_REPO|GH_REPO="\$(touch @SENTINEL@)/r" gh issue create --title x
substitution in GH_HOST|GH_HOST="\$(touch @SENTINEL@)" gh issue create --repo $OWNER/agents
semicolon in a hostname|gh --hostname "h;touch @SENTINEL@" issue create --repo $OWNER/agents
backtick in a hostname|gh --hostname "\`touch @SENTINEL@\`" issue create --repo $OWNER/agents
substitution in an api endpoint|gh api -X POST "repos/\$(touch @SENTINEL@)/r/issues" -f t=x
TABLE

    # The symmetric control: an ordinary owned target sharing the same code path
    # must still resolve silently, so C10-3 is not passing on a guard that has
    # simply started asking at everything.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C10-4 the clean owned target is unaffected -> silent allow" "silent"

    # The sentinel mechanism itself must be able to fire, or every row above is
    # vacuous. Proven by running it through the same shell the payload strings
    # are built in — if this does NOT create the file, C10-3 proves nothing.
    rm -f "$BASE/pwned-selfcheck"
    ( eval "touch $BASE/pwned-selfcheck" ) >/dev/null 2>&1
    if [ -e "$BASE/pwned-selfcheck" ]; then
        pass "C10-5 the sentinel mechanism is live (self-check)"
    else
        fail "C10-5 sentinel self-check" "touch sentinel did not fire — C10-3 would be vacuous"
    fi
    rm -f "$BASE/pwned-selfcheck"

    unset -f _no_leak
}
