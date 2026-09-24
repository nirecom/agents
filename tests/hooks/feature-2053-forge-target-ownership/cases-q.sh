#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block Q — auth context (C49 / C52 / C55).

run_block_q() {
    echo ""
    echo "=== Q: the identity that PROVES must be the identity that WRITES ==="

    # The hook probes with its own credentials; the command may run with others.
    # When the two can differ, ownership proven here says nothing about there —
    # so an explicit, provably-owned target must still ask.
    reset_env
    run_case "$FX_OWNED" "GH_TOKEN=xxx gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-1 inline GH_TOKEN with an owned target -> ask" "ask" "auth-context-change"
    assert_probes "Q-7 a changed auth context probes nothing (gh api user)" "api user" 0
    assert_probes "Q-7b and no capability query either" "api repos/" 0

    reset_env
    run_case "$FX_OWNED" "GITHUB_TOKEN=xxx gh issue create --repo $OWNER/agents"
    assert_decision "Q-2a inline GITHUB_TOKEN -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "GH_CONFIG_DIR=/tmp/x gh issue create --repo $OWNER/agents"
    assert_decision "Q-2b inline GH_CONFIG_DIR -> ask" "ask" "auth-context-change"

    # Q-3/Q-4 are a pair. The hook runs BEFORE the command, so a switch that
    # precedes the write invalidates the proof; one that follows it does not.
    # Implementing propagation as "anywhere in the line" breaks Q-4.
    reset_env
    run_case "$FX_OWNED" "gh auth switch --user $FOREIGN && gh issue create --repo $OWNER/agents"
    assert_decision "Q-3 auth switch BEFORE the write -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents && gh auth switch --user x"
    assert_decision "Q-4 auth switch AFTER the write -> silent allow" "silent"

    reset_env
    run_case "$FX_OWNED" "export GH_TOKEN=xxx
gh issue create --repo $OWNER/agents"
    assert_decision "Q-5a exported token then a write -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "git credential fill && gh issue create --repo $OWNER/agents"
    assert_decision "Q-5b a credential helper first -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "source ~/.envrc && gh issue create --repo $OWNER/agents"
    assert_decision "Q-5c sourcing an unknown file first -> ask" "ask" "auth-context-change"

    # Q-6: the array payload is one shell context, so the switch in element 1
    # reaches the write in element 2.
    reset_env
    run_tool_case "runCommands" "$FX_OWNED" "gh auth switch --user x" \
        "gh issue create --repo $OWNER/agents"
    assert_decision "Q-6 auth switch propagates across array elements -> ask" "ask" \
        "auth-context-change"

    # Q-8: assignments unrelated to authentication must stay quiet, and a command
    # that writes nothing is not this guard's business at all.
    reset_env
    run_case "$FX_OWNED" "MSYS_NO_PATHCONV=1 gh issue create --repo $OWNER/agents"
    assert_decision "Q-8a an unrelated inline assignment -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "gh auth status"
    assert_decision "Q-8b gh auth status writes nothing -> passThrough" "silent"
    assert_probes "Q-8b2 no probe spent" "api user" 0

    echo ""
    echo "=== Q (C52): the env wrapper eats assignments, so it must be scanned ==="

    # `env GH_TOKEN=x gh ...` peels to a plain `gh ...`: the assignment is gone
    # by the time the detector looks, and the write would sail through proven.
    reset_env
    run_case "$FX_OWNED" "env GH_TOKEN=xxx gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-9 env-wrapped GH_TOKEN with an owned target -> ask" "ask" \
        "auth-context-change"
    assert_probes "Q-9b and it probes nothing" "api user" 0

    reset_env
    run_case "$FX_OWNED" "env -u GH_TOKEN gh issue create --repo $OWNER/agents"
    assert_decision "Q-10a env -u GH_TOKEN -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "env -uGH_TOKEN gh issue create --repo $OWNER/agents"
    assert_decision "Q-10b attached env -uGH_TOKEN -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "env --unset=GH_TOKEN gh issue create --repo $OWNER/agents"
    assert_decision "Q-10c env --unset=GH_TOKEN -> ask" "ask" "auth-context-change"

    reset_env
    run_case "$FX_OWNED" "env -i gh issue create --repo $OWNER/agents"
    assert_decision "Q-11a env -i clears the environment -> ask" "ask" "auth-context-change"
    # env -S carries a whole program string: that is an unrecognized wrapper head,
    # a DIFFERENT failure mode, and the reason code must say so.
    reset_env
    run_case "$FX_OWNED" "env -S 'gh issue create --repo $FOREIGN/x'"
    assert_decision "Q-11b env -S is a wrapper-head problem, not an auth one" "ask" \
        "unrecognized-wrapper-head"
    assert_reason_lacks "auth-context-change" "Q-11b2 env -S is not misreported as auth"
    reset_env
    run_case "$FX_OWNED" "env -Q x gh issue create --repo $OWNER/agents"
    assert_decision "Q-11c an unknown env option -> ask" "ask"

    reset_env
    run_case "$FX_OWNED" "env MSYS_NO_PATHCONV=1 gh issue create --repo $OWNER/agents"
    assert_decision "Q-12a an unrelated env assignment -> silent allow" "silent"
    # env -C is a cwd problem, not an auth problem — separate reasons, so the
    # user is told the truth about why they are being asked.
    reset_env
    run_case "$FX_OWNED" "env -C $FX_FOREIGN gh issue create --repo $OWNER/agents"
    assert_decision "Q-12b env -C relocates the cwd -> ask" "ask"
    assert_reason_lacks "auth-context-change" "Q-12b2 env -C is not misreported as auth"
    reset_env
    run_case "$FX_OWNED" "env A=1 env GH_TOKEN=x gh issue create --repo $OWNER/agents"
    assert_decision "Q-12c every env stage in the chain is scanned -> ask" "ask" \
        "auth-context-change"

    echo ""
    echo "=== Q (C55): the terminal's environment outlives one tool call ==="

    # `export GH_TOKEN=...` persists in the Bash tool's shell. A later call is a
    # fresh hook PROCESS that would otherwise re-probe with its own identity and
    # allow the write, while the terminal still runs with the exported token.
    reset_env
    run_case "$FX_OWNED" "export GH_TOKEN=xxx"
    assert_decision "Q-13a the export alone writes nothing -> passThrough" "silent"
    if [ -f "$CLAUDE_WORKFLOW_DIR/$SID.gh-auth-dirty" ]; then
        pass "Q-13b the session is marked auth-dirty"
    else
        fail "Q-13b auth-dirty marker" "no $SID.gh-auth-dirty in $CLAUDE_WORKFLOW_DIR"
    fi
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-13c the NEXT call still asks -> ask" "ask" "auth-context-change"
    assert_probes "Q-13d and it probes nothing" "api user" 0

    reset_env
    run_case "$FX_OWNED" "gh auth switch --user x"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-13e auth switch persists across calls -> ask" "ask" "auth-context-change"
    reset_env
    run_case "$FX_OWNED" "source ~/.envrc"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-13f a sourced file persists across calls -> ask" "ask" "auth-context-change"

    # Q-14: the flag has to be scoped and releasable, or it becomes a permanent
    # "always ask" that trains the user to click through.
    reset_env
    run_case "$FX_OWNED" "GH_TOKEN=x gh api user"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-14a a segment-scoped assignment does not persist -> silent" "silent"
    reset_env
    run_case "$FX_OWNED" "env GH_TOKEN=x gh api user"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-14b env-wrapped, segment-scoped, does not persist -> silent" "silent"
    reset_env
    run_case "$FX_OWNED" "export GH_TOKEN=x"
    resume_case "$FX_OWNED" "unset GH_TOKEN"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-14c unset clears the export cause -> silent allow" "silent"
    # An auth switch is not undone by unsetting a variable.
    reset_env
    run_case "$FX_OWNED" "gh auth switch --user x"
    resume_case "$FX_OWNED" "unset GH_TOKEN"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "Q-14d unset does not clear an auth switch -> ask" "ask" "auth-context-change"

    # SKIPPED: the 4-hour TTL expiry of the auth-dirty flag.
    # Because: TL2 has no clock knob; forcing it would only test a stubbed clock.
    # L3 gap: only a long-lived real session proves the flag ages out.
    # Q-14(e) — Bash-tool writes to <sid>.gh-auth-dirty must be BLOCKED — is a
    # protected-basenames concern and lives in
    # tests/enforce-protected-marker-write/cases-forge-ownership-state.sh.
}
