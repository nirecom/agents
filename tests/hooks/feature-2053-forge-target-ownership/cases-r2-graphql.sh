#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Round-2 C9 — `gh api graphql`: opaque bodies and query/mutation precedence.
#
# WHY: one endpoint/method — the DOCUMENT decides, and need not be on the
# command line (`--input file`, `--input -`, `-F query=@file`; H-20..H-22
# cover the inline/file shapes). passThrough is earned only by a document the
# guard can see and prove read-only — an unreadable body asks, the right
# trade for an endpoint whose purpose includes createIssue.

run_block_r2_graphql() {
    echo ""
    echo "=== R2-C9-1: an unreadable document is never proven read-only ==="

    local body_file="$BASE/r2-graphql-body.json"
    printf '{"query":"query{viewer{login}}"}' > "$body_file"
    local mut_file="$BASE/r2-graphql-mutation.gql"
    printf 'mutation{createIssue(input:{repositoryId:"x",title:"y"}){clientMutationId}}' > "$mut_file"

    # Every row hands the document over by a route the argv cannot show. Even the
    # rows whose FILE happens to hold a plain query must ask: the guard classifies
    # the command, and reading the file at hook time would be both a TOCTOU race
    # and an arbitrary-file read driven by untrusted argv.
    local name cmd
    while IFS='|' read -r name cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "R2-C9-1 [$name] opaque document -> ask" "ask"
        assert_eq "R2-C9-1 [$name] and the hook still exits 0" "0" "$HOOK_RC"
    done <<TABLE
--input FILE|gh api graphql --input $body_file
--input= attached FILE|gh api graphql --input=$body_file
--input - (stdin)|gh api graphql --input -
--input=- attached stdin|gh api graphql --input=-
mutation supplied only through a file|gh api graphql --input $mut_file
-F query=@FILE mutation|gh api graphql -F query=@$mut_file
-F query=@- stdin|gh api graphql -F query=@-
--field query=@FILE|gh api graphql --field query=@$body_file
--raw-field query=@FILE|gh api graphql --raw-field query=@$body_file
absolute graphql URL with --input|gh api https://api.github.com/graphql --input $body_file
query flag with no value|gh api graphql -f query=
query value is a variable|gh api graphql -f query="\$Q"
query value is a substitution|gh api graphql -f query="\$(cat $mut_file)"
TABLE

    echo ""
    echo "=== R2-C9-2: repeated query fields — precedence in BOTH orders ==="

    # pflag keeps the LAST value of a repeated flag, so the effective document is
    # the last one. A classifier that scans for "does any -f query contain
    # mutation" fails the query-last row by over-asking; one that reads only the
    # first field fails the mutation-last row by allowing a mutation. Both rows
    # must hold at once, which is what forces last-occurrence semantics.
    while IFS='|' read -r name cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "R2-C9-2 [$name] -> ask" "ask"
    done <<TABLE
query then mutation (mutation is effective)|gh api graphql -f query='query{viewer{login}}' -f query='mutation{createIssue(input:{}){id}}'
mutation then query (mutation is shadowed but present)|gh api graphql -f query='mutation{createIssue(input:{}){id}}' -f query='query{viewer{login}}'
mutation inline then a file|gh api graphql -f query='mutation{createIssue(input:{}){id}}' --input $body_file
query inline then a file|gh api graphql -f query='query{viewer{login}}' --input $body_file
-F then -f, mutation last|gh api graphql -F query='query{viewer{login}}' -f query='mutation{createIssue(input:{}){id}}'
mutation as an operation name only|gh api graphql -f query='mutation R2 { createIssue(input:{}){id} }'
anonymous mutation shorthand|gh api graphql -f query='  mutation  {createIssue(input:{}){id}}'
mutation with a leading tab|gh api graphql -f query='	mutation{createIssue(input:{}){id}}'
TABLE

    echo ""
    echo "=== R2-C9-3: the readable read-only document is still cheap ==="

    # The counterweight. A guard that asks at every `gh api graphql` would pass
    # every row above while making the endpoint unusable, so the shapes whose
    # document IS visible and IS a query must stay passThrough — and must spend
    # no ownership probe, which is what tells passThrough apart from silent allow.
    local q
    for q in "query{viewer{login}}" "{viewer{login}}" "query R2Named { viewer { login } }"; do
        reset_env
        run_case "$FX_OWNED" "gh api graphql -f query='$q'"
        assert_decision "R2-C9-3 [$q] a visible read-only document -> passThrough" "silent"
        assert_probes "R2-C9-3 [$q] no ownership probe was spent" "api user" 0
    done

    rm -f "$body_file" "$mut_file"
}
