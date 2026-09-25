#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C7 — host selection on the COMMAND LINE, not only via GH_HOST.

# WHY: ownership is proven against one forge. Block C only covered the GH_HOST
# environment spelling, but gh takes a host from --hostname, from a
# host-qualified [HOST/]OWNER/REPO selector, and from GH_HOST — and the three can
# disagree. Any host the guard cannot pin to github.com makes the proof it just
# performed irrelevant, so the verdict is ask.

run_block_c7() {
    echo ""
    echo "=== C7-1: --hostname on the gh command line ==="

    local name cmd want
    # want column: ask | silent. Every row targets $OWNER/agents — a repo the
    # stub proves owned — so a row that asks can only be asking about the HOST.
    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "C7 [$name]" "$want"
    done <<TABLE
--hostname enterprise|ask|gh --hostname ghe.example.com issue create --repo $OWNER/agents --title x
--hostname= enterprise|ask|gh --hostname=ghe.example.com issue create --repo $OWNER/agents --title x
--hostname github.com|silent|gh --hostname github.com issue create --repo $OWNER/agents --title x
--hostname= github.com|silent|gh --hostname=github.com issue create --repo $OWNER/agents --title x
--hostname with no value|ask|gh --hostname issue create --repo $OWNER/agents --title x
--hostname empty value|ask|gh --hostname= issue create --repo $OWNER/agents --title x
--hostname after subcommand|ask|gh issue create --hostname ghe.example.com --repo $OWNER/agents --title x
--hostname unread variable|ask|gh --hostname \$HOSTVAR issue create --repo $OWNER/agents --title x
--hostname lookalike|ask|gh --hostname github.com.evil.com issue create --repo $OWNER/agents --title x
--hostname uppercase github|silent|gh --hostname GITHUB.COM issue create --repo $OWNER/agents --title x
api --hostname enterprise|ask|gh api --hostname ghe.example.com -X POST repos/$OWNER/agents/issues -f t=x
api --hostname github.com|silent|gh api --hostname github.com -X POST repos/$OWNER/agents/issues -f t=x
TABLE

    echo ""
    echo "=== C7-2: host-qualified [HOST/]OWNER/REPO selectors ==="

    # A three-segment selector is gh's own spelling for "this repo on that host".
    # Read as a two-segment OWNER/REPO it becomes a repo named "OWNER/REPO" under
    # an owner named after the host — nonsense that must never resolve to owned.
    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "C7 [$name]" "$want"
    done <<TABLE
host-qualified github.com owned|silent|gh issue create --repo github.com/$OWNER/agents --title x
host-qualified github.com foreign|ask|gh issue create --repo github.com/$FOREIGN/r --title x
host-qualified enterprise owned name|ask|gh issue create --repo ghe.example.com/$OWNER/agents --title x
host-qualified attached short|ask|gh issue create -Rghe.example.com/$OWNER/agents --title x
host-qualified four segments|ask|gh issue create --repo a/b/c/d --title x
host-qualified lookalike host|ask|gh issue create --repo github.com.evil.com/$OWNER/agents --title x
host-qualified with scheme|ask|gh issue create --repo https://github.com/$OWNER/agents --title x
TABLE

    echo ""
    echo "=== C7-3: precedence conflicts between GH_HOST and --hostname ==="

    # gh resolves one effective host. When the two spellings disagree the guard
    # has to name a host to prove against; guessing the wrong one is exactly the
    # silent cross-forge write this guard exists to stop, so conflict -> ask.
    reset_env
    run_case "$FX_OWNED" "GH_HOST=github.com gh --hostname ghe.example.com issue create --repo $OWNER/agents"
    assert_decision "C7-3a GH_HOST=github.com but --hostname enterprise -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "GH_HOST=ghe.example.com gh --hostname github.com issue create --repo $OWNER/agents"
    assert_decision "C7-3b GH_HOST enterprise but --hostname github.com -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "GH_HOST=github.com gh --hostname github.com issue create --repo $OWNER/agents"
    assert_decision "C7-3c both spellings agree on github.com -> silent allow" "silent"

    # Rank-4 symmetry with block C: the same conflict with GH_HOST arriving from
    # the hook process's own environment instead of an inline assignment.
    reset_env; add_env "GH_HOST=ghe.example.com"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C7-3d process-env GH_HOST=<enterprise> -> ask" "ask"
    reset_env; add_env "GH_HOST=ghe.example.com"
    run_case "$FX_OWNED" "gh --hostname github.com issue create --repo $OWNER/agents"
    assert_decision "C7-3e process-env enterprise vs --hostname github.com -> ask" "ask"
    reset_env; add_env "GH_HOST=github.com"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C7-3f process-env GH_HOST=github.com -> silent allow" "silent"

    # A host selector on an OUT-OF-SCOPE verb must stay out of scope: the host
    # question is not itself a reason to start prompting.
    reset_env
    run_case "$FX_OWNED" "gh --hostname ghe.example.com issue list --repo $FOREIGN/r"
    assert_decision "C7-4 an enterprise host on issue list -> passThrough" "silent"
    assert_probes "C7-4b and no probe is spent" "api user" 0

    # The implicit target inherits the host question too: a checkout whose origin
    # is on another forge cannot be proven by a github.com identity probe.
    local FX_GHE
    FX_GHE="$(mkfixture ghehost "https://ghe.example.com/$OWNER/agents.git")"
    reset_env
    run_case "$FX_GHE" "gh issue create --title x"
    assert_decision "C7-5 an enterprise ORIGIN with a matching login -> ask" "ask"
    reset_env
    run_case "$FX_GHE" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C7-5b explicit github.com target from that cwd -> silent allow" "silent"
}
