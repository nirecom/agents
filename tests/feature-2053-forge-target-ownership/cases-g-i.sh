#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks G (probe budget), H (gh api argv scan + endpoint classification),
# I (proof ladder and per-session cache).

run_block_g_i() {
    echo ""
    echo "=== G: budget — a guard that can hang is a guard that gets disabled ==="

    # The stub sleeps far longer than the whole hook is allowed to take. The
    # contract is a bounded wall clock AND a fail-closed verdict, never one alone.
    reset_env; add_env "GH_STUB_SLEEP=30"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "G-1 a hanging gh still yields a decision -> ask" "ask"
    if [ "$ELAPSED_MS" -lt 10000 ]; then
        pass "G-1b hook returned in ${ELAPSED_MS}ms (<10s registered timeout)"
    else
        fail "G-1b hook budget" "took ${ELAPSED_MS}ms, must stay under the 10s hook timeout"
    fi

    reset_env; add_env "GH_STUB_SLEEP=30"
    run_case "$FX_OWNED" "gh issue create --repo a/b --repo c/d --repo e/f --repo g/h --repo i/j --title x"
    assert_decision "G-2 five targets under a hanging gh -> ask" "ask"
    if [ "$ELAPSED_MS" -lt 10000 ]; then
        pass "G-2b five targets still returned in ${ELAPSED_MS}ms"
    else
        fail "G-2b hook budget" "five targets took ${ELAPSED_MS}ms, budget is not per-target"
    fi

    # The local git probe is on the same budget as the network probes.
    local slowbin="$BASE/slowbin"; mkdir -p "$slowbin"
    printf '#!/usr/bin/env bash\nsleep 30\nexec %s "$@"\n' "$(command -v git)" > "$slowbin/git"
    chmod +x "$slowbin/git"
    reset_env; add_env "PATH=$slowbin:$MOCKBIN:$PATH"
    run_case "$FX_OWNED" "gh issue create --title x"
    assert_decision "G-3 a hanging local git probe -> ask" "ask"
    if [ "$ELAPSED_MS" -lt 10000 ]; then
        pass "G-3b git probe is bounded too (${ELAPSED_MS}ms)"
    else
        fail "G-3b hook budget" "git probe took ${ELAPSED_MS}ms"
    fi

    echo ""
    echo "=== H: gh api — argv scan and endpoint classification ==="

    # passThrough and silent-allow are the same bytes on stdout ({}), so the two
    # are told apart by whether the hook spent any ownership probe at all.
    h_ask()   { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "ask"; }
    h_pass()  { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "silent"
                assert_probes "$1 [out of scope: no probe spent]" "api user" 0; }
    h_allow() { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "silent"
                assert_probes "$1 [in scope: ownership actually proven]" "api user" 1; }

    h_ask   "H-1 -X POST repos/<foreign>/r/issues -> ask" \
            "gh api -X POST repos/$FOREIGN/r/issues -f title=x"
    # The real shape used by bin/github-issues/issue-create-dispatch.sh.
    h_allow "H-2 sub_issues on an owned repo -> silent allow" \
            "gh api -X POST repos/$OWNER/agents/issues/1/sub_issues -f sub_issue_id=1"
    h_ask   "H-3 a header flag before the endpoint -> ask" \
            "gh api -H \"Accept: application/vnd.github+json\" -X POST repos/$FOREIGN/r/issues"
    h_ask   "H-4 --jq before the endpoint -> ask" \
            "gh api --jq .x repos/$FOREIGN/r/issues -f title=y"
    h_ask   "H-5 attached short -XPOST -> ask" \
            "gh api -XPOST repos/$FOREIGN/r/issues -f title=x"
    h_pass  "H-6 -X GET is a read -> passThrough" \
            "gh api -X GET repos/$FOREIGN/r/issues -f state=open"
    h_pass  "H-7 attached long --method=GET is a read -> passThrough" \
            "gh api --method=GET repos/$FOREIGN/r/issues -f state=open"
    h_ask   "H-8 an unknown flag makes the argv ambiguous -> ask" \
            "gh api --unknown-flag x repos/$FOREIGN/r/issues -f a=b"
    h_ask   "H-9 implicit POST (fields, no method) -> ask" \
            "gh api repos/$FOREIGN/r/issues -f title=x"

    h_ask   "H-10 absolute api.github.com URL, foreign -> ask" \
            "gh api -X POST https://api.github.com/repos/$FOREIGN/repo/issues -f title=x"
    h_allow "H-11 absolute api.github.com URL, owned -> silent allow" \
            "gh api -X POST https://api.github.com/repos/$OWNER/agents/issues -f title=x"
    h_ask   "H-12 an enterprise host URL -> ask" \
            "gh api -X POST https://ghe.example.com/api/v3/repos/$OWNER/agents/issues -f title=x"
    # A lookalike host is not github.com; owning the repo NAME proves nothing there.
    h_ask   "H-13 schemeless lookalike host, owned repo name -> ask" \
            "gh api -X POST api.github.com.evil.com/repos/$OWNER/agents/issues -f title=x"
    h_ask   "H-14 schemeless api.github.com, foreign -> ask" \
            "gh api -X POST api.github.com/repos/$FOREIGN/r/issues -f title=x"
    h_allow "H-15 schemeless api.github.com, owned -> silent allow" \
            "gh api -X POST api.github.com/repos/$OWNER/agents/issues -f title=x"
    # An id-addressed repo cannot be resolved to an owner at all.
    h_ask   "H-16 repositories/<id>/issues -> ask" \
            "gh api -X POST repositories/12345/issues -f title=x"
    h_ask   "H-17 leading-slash path -> ask" \
            "gh api -X POST /repos/$FOREIGN/r/issues -f title=x"

    h_pass  "H-18 gists are not repo-scoped -> passThrough" "gh api -X POST gists -f x=y"
    h_pass  "H-19 user/repos creates under the caller -> passThrough" \
            "gh api -X POST user/repos -f name=x"

    h_ask   "H-20 a graphql mutation -> ask" \
            "gh api graphql -f query='mutation{createIssue(input:{}){clientMutationId}}'"
    h_pass  "H-21 a graphql query -> passThrough" "gh api graphql -f query='query{viewer{login}}'"
    h_ask   "H-22 a graphql body from a file -> ask" "gh api graphql -F query=@q.gql"

    # H-C50-1: the approved scope is issue-CREATION endpoints (intent.md:28 —
    # "gh issue create / gh api (issue creation endpoints)"). Other repo writes
    # staying silent is the boundary the user approved, not a missed detection.
    h_pass  "H-C50-1a contents PUT is outside the approved scope -> passThrough" \
            "gh api -X PUT repos/$FOREIGN/r/contents/x -f message=y"
    h_pass  "H-C50-1b releases POST is outside the approved scope -> passThrough" \
            "gh api -X POST repos/$FOREIGN/r/releases -f tag_name=v1"
    h_pass  "H-C50-1c labels POST is outside the approved scope -> passThrough" \
            "gh api -X POST repos/$FOREIGN/r/labels -f name=x"
    # H-C50-2: the issues subtree IS in scope. Comments are not issue creation,
    # so this ask is wider than the stated intent — the residual recorded as
    # Risk 27 (C56), kept deliberately rather than narrowed by guesswork.
    h_ask   "H-C50-2 issue comments are inside the issues subtree -> ask" \
            "gh api -X POST repos/$FOREIGN/r/issues/1/comments -f body=x"

    # H-C54: a query string or fragment must not push an issues endpoint out of
    # the subtree. Before normalization these fell through to silent allow.
    h_ask   "H-C54-1a query string on a foreign issues endpoint -> ask" \
            "gh api -X POST 'repos/$FOREIGN/r/issues?foo=bar' -f title=x"
    h_allow "H-C54-1b the owned contrast stays a silent allow" \
            "gh api -X POST 'repos/$OWNER/agents/issues?foo=bar' -f title=x"
    h_ask   "H-C54-2 a fragment on a foreign issues endpoint -> ask" \
            "gh api -X POST 'repos/$FOREIGN/r/issues#frag' -f title=x"
    h_pass  "H-C54-3a truncation does not drag contents PUT into scope" \
            "gh api -X PUT 'repos/$FOREIGN/r/contents/x?ref=main' -f message=y"
    h_pass  "H-C54-3b a repo-root read with a query stays passThrough" \
            "gh api 'repos/$FOREIGN/r?x=1'"
    # H-C54-4: the discarded part must not steer resolution either — an owned
    # repo named only inside the query string cannot make a foreign path owned.
    h_ask   "H-C54-4 owner named only in the query string does not count" \
            "gh api -X POST 'repos/$FOREIGN/r/issues?repo=$OWNER/agents' -f title=x"

    unset -f h_ask h_pass h_allow

    echo ""
    echo "=== I: proof ladder and the per-session cache ==="

    reset_env; add_env "GH_STUB_LOGIN=other"; add_env "GH_STUB_ADMIN=true"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "I-1 login differs but admin capability -> silent allow" "silent"
    reset_env; add_env "GH_STUB_LOGIN=other"; add_env "GH_STUB_ADMIN=false"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "I-2 login differs and no admin capability -> ask" "ask"
    reset_env; add_env "GH_STUB_EXIT=1"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "I-3 a non-zero gh exit proves nothing -> ask" "ask"
    reset_env; add_env "GH_STUB_SLEEP=30"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "I-4 a timed-out probe proves nothing -> ask" "ask"
    # I-5 (round-2 C11): gh, and ONLY gh, missing. The previous form replaced
    # PATH with an empty directory, which also removed the bash that runs the
    # `#!/usr/bin/env bash` timeout wrapper and the node that runs the hook: the
    # result was a harness crash dressed up as a verdict, and it would have passed
    # identically against a guard that fails open. path_without_gh keeps every
    # PATH entry that carries no gh, so the interpreter chain survives intact.
    local NOGH; NOGH="$(path_without_gh)"
    if PATH="$NOGH" command -v gh >/dev/null 2>&1; then
        fail "I-5a the fixture PATH really has no gh" "gh is still resolvable — I-5 would be vacuous"
    else
        pass "I-5a the fixture PATH really has no gh"
    fi
    # The premise the old form silently broke. Without these, "ask" below could
    # mean "the guard fails closed" or "nothing ever started".
    local missing_tool=""
    for _t in bash node git; do
        PATH="$NOGH" command -v "$_t" >/dev/null 2>&1 || missing_tool="$missing_tool $_t"
    done
    assert_eq "I-5b bash, node and git are still reachable (only gh was removed)" "" "$missing_tool"
    reset_env; add_env "PATH=$NOGH"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "I-5c gh missing from PATH -> ask" "ask"
    # A crash is not a verdict. rc 0 is what separates "decided to ask" from
    # "died before deciding", which is the exact confusion round-2 C11 named.
    assert_eq "I-5d and the hook exited 0 rather than crashing" "0" "$HOOK_RC"

    # Cache identity: the cached answer belongs to an auth fingerprint, so
    # changing the token that would be used invalidates it and forces a re-probe.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_probes "I-6a first call probes the login once" "api user" 1
    add_env "GH_TOKEN=different-token"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title y"
    assert_probes "I-6b a changed auth fingerprint re-probes" "api user" 1

    # SKIPPED: cache TTL expiry forcing a re-probe within one session.
    # Because: the TTL is measured in hours and TL2 cannot advance the clock.
    # L3 gap: only a long-running real session exercises the expiry branch.
}
