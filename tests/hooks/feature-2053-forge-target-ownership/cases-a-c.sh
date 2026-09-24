#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks A (silent allow + probe counters), B (ownership regression),
# C (GH_REPO / GH_HOST assignment forms and rank precedence).

run_block_a_c() {
    echo ""
    echo "=== A: silent allow, and the probe budget that makes it affordable ==="

    # A repeated probe per target is how a guard becomes slow enough to be turned
    # off, so the counters are asserted alongside the decision, not instead of it.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "A-1 explicit owned target -> silent allow" "silent"
    assert_probes "A-1 gh api user probed exactly once" "api user" 1
    # P1 (login match) settles ownership on its own; the capability query is the
    # rung below it and must not run when P1 already answered.
    assert_probes "A-1 no repos capability probe when login matches" "api repos/" 0

    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title y"
    assert_decision "A-2 same session, same target -> still silent" "silent"
    assert_probes "A-2 login is cached for the session (0 re-probes)" "api user" 0

    reset_env
    run_case "$FX_OWNED" "gh api repos/$OWNER/agents/issues -f title=x"
    assert_decision "A-3 gh api issues endpoint on an owned repo -> silent allow" "silent"

    reset_env
    run_case "$FX_OWNED" "gh issue create --title x --body y"
    assert_decision "A-4 bare create in an owned, non-fork checkout -> silent allow" "silent"

    # P2: an org / collaborator repo the login does not literally own is allowed
    # only on a positive capability answer, and only one query per target.
    reset_env; add_env "GH_STUB_LOGIN=orgmember"; add_env "GH_STUB_ADMIN=true"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "A-5 admin capability on a non-login owner -> silent allow" "silent"
    assert_probes "A-5 repos capability probed exactly once" "api repos/" 1
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title z"
    assert_probes "A-6 same target is not re-queried in the session" "api repos/" 0

    echo ""
    echo "=== B: ownership regression — the incident this guard exists for ==="

    # #2053 itself: a checkout whose origin belongs to someone else. Both the
    # implicit (cwd-derived) and the explicit target must stop.
    reset_env
    run_case "$FX_FOREIGN" "gh issue create --title x --body y"
    assert_decision "B-1 bare create in a foreign checkout -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $FOREIGN/repo --title x"
    assert_decision "B-2 explicit foreign target from an owned cwd -> ask" "ask"

    echo ""
    echo "=== C: GH_REPO / GH_HOST — every assignment form, and rank precedence ==="

    reset_env
    run_case "$FX_OWNED" "GH_REPO=$FOREIGN/repo gh issue create --title x"
    assert_decision "C-1 inline GH_REPO naming a foreign repo -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "GH_REPO=$OWNER/agents gh issue create --title x"
    assert_decision "C-2 inline GH_REPO naming an owned repo -> silent allow" "silent"

    reset_env
    run_case "$FX_OWNED" "export GH_REPO=$FOREIGN/repo
gh issue create --title x"
    assert_decision "C-3 exported GH_REPO (foreign) then bare create -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "export GH_REPO=$OWNER/agents
gh issue create --title x"
    assert_decision "C-4 exported GH_REPO (owned, matches cwd) -> silent allow" "silent"

    # C25: an exported owned GH_REPO must not launder a foreign cwd. Both targets
    # are in scope, so BOTH have to appear in the reason the user reads.
    reset_env
    run_case "$FX_FOREIGN" "export GH_REPO=$OWNER/agents"
    resume_case "$FX_FOREIGN" "gh issue create --title x"
    assert_decision "C25-1 owned GH_REPO + foreign cwd -> ask" "ask" "$FOREIGN/repo"
    assert_decision "C25-2 the reason names the GH_REPO target too" "ask" "$OWNER/agents"

    # Rank-4 symmetry: the same precedence question, with GH_REPO arriving from
    # the hook process's own environment instead of an observed assignment.
    reset_env; add_env "GH_REPO=$OWNER/agents"
    run_case "$FX_FOREIGN" "gh issue create --title x"
    assert_decision "C25-3 process-env GH_REPO + foreign cwd -> ask" "ask" "$FOREIGN/repo"
    assert_decision "C25-4 process-env case also names both targets" "ask" "$OWNER/agents"

    # C14: the nearer assignment wins. An owned value observed earlier must not
    # shadow the inline foreign value that the command actually runs with.
    reset_env
    run_case "$FX_OWNED" "export GH_REPO=$OWNER/agents"
    resume_case "$FX_OWNED" "GH_REPO=$FOREIGN/x gh issue create --title t"
    assert_decision "C14-1 inline foreign beats an earlier exported owned -> ask" "ask" "$FOREIGN/x"

    reset_env; add_env "GH_REPO=$OWNER/agents"
    run_case "$FX_OWNED" "GH_REPO=$FOREIGN/x gh issue create --title t"
    assert_decision "C14-2 inline foreign beats process-env owned -> ask" "ask" "$FOREIGN/x"

    reset_env
    run_case "$FX_OWNED" "export GH_REPO=$FOREIGN/x"
    resume_case "$FX_OWNED" "GH_REPO=$OWNER/agents gh issue create --title t"
    assert_decision "C14-3 inline owned beats an earlier exported foreign -> silent" "silent"

    # C22: a two-line payload is one Bash call. The cd is real, so the second
    # line's implicit target is the foreign checkout, not the tool's cwd.
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN
gh issue create --repo $FOREIGN/repo --title x"
    assert_decision "C22-1 cd + explicit foreign target -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN
gh issue create --repo $OWNER/agents --title x"
    assert_decision "C22-2 cd + explicit owned target -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN
gh issue create --title x"
    assert_decision "C22-3 cd + bare create -> ask" "ask"

    # An assignment whose value is a bare variable is rejected at the literal
    # check, before any owner/repo charset question — so the reason must be about
    # the unreadable GH_REPO value, and must not claim a resolved owner/repo.
    reset_env
    run_case "$FX_OWNED" "export GH_REPO=\$SOMEVAR"
    resume_case "$FX_OWNED" "gh issue create --title x"
    assert_decision "C-5 GH_REPO=\$VAR -> ask, reason names GH_REPO" "ask" "GH_REPO"
    assert_reason_lacks "\$SOMEVAR" "C-6 the unread value is not echoed back as a target"

    reset_env
    run_case "$FX_OWNED" "export GH_REPO=$FOREIGN/x"
    resume_case "$FX_OWNED" "unset GH_REPO"
    resume_case "$FX_OWNED" "gh issue create --title x"
    assert_decision "C-7 unset GH_REPO returns to cwd-derived resolution -> silent" "silent"

    # SKIPPED: TTL expiry of an observed GH_REPO returning to cwd resolution.
    # Because: the TTL is hours long and TL2 has no clock knob to advance it.
    # L3 gap: only a long-lived real session proves the observed value ages out.

    # No false positives: merely MENTIONING GH_REPO must not arm anything. If it
    # did, every grep and commit message in this repo would start asking.
    reset_env
    run_case "$FX_OWNED" "rg GH_REPO hooks/"
    assert_decision "C-8 rg GH_REPO is not an assignment -> silent (passThrough)" "silent"
    resume_case "$FX_OWNED" "gh issue create --title x"
    assert_decision "C-9 a later bare create is still silently allowed" "silent"
    reset_env
    run_case "$FX_OWNED" "git commit -m \"handle GH_REPO\""
    assert_decision "C-10 GH_REPO inside a commit message -> silent (passThrough)" "silent"
    resume_case "$FX_OWNED" "gh issue create --title x"
    assert_decision "C-11 a later bare create is still silently allowed" "silent"

    # GH_HOST moves the write to a different forge entirely; ownership proven on
    # github.com says nothing there.
    reset_env
    run_case "$FX_OWNED" "GH_HOST=ghe.example.com gh issue create --repo $OWNER/agents --title x"
    assert_decision "C-12 GH_HOST=<enterprise> even with an owned target -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "GH_HOST=github.com gh issue create --repo $OWNER/agents --title x"
    assert_decision "C-13 GH_HOST=github.com with an owned target -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "export GH_HOST=\$SOMEVAR"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C-14 unreadable GH_HOST -> ask even for an owned target" "ask"
}
