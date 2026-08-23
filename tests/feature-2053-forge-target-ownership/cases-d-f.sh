#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks D (repo selectors incl. C47), E (cwd allowlist), F (tool payload shapes).

run_block_d_f() {
    echo ""
    echo "=== D: repo selectors — every named target is in scope, not just the last ==="

    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --repo $FOREIGN/r --title x"
    assert_decision "D-1 owned then foreign selector -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create -R $OWNER/agents --repo $FOREIGN/r --title x"
    assert_decision "D-2 mixed -R / --repo, one foreign -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --repo $OWNER/agents --title x"
    assert_decision "D-3 the same owned selector twice -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo --title x"
    assert_decision "D-4 --repo with no value -> ask (named but unresolvable)" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create -- --repo $FOREIGN/r"
    assert_decision "D-5 after --, --repo is an operand, so cwd decides -> silent" "silent"

    # C47: gh (pflag) accepts the attached short form. If the guard cannot read it
    # the selector count is zero, the resolver falls back to the OWNED cwd, and a
    # foreign write is silently allowed — the exact failure #2053 reports.
    reset_env
    run_case "$FX_OWNED" "gh issue create -R$FOREIGN/repo --title x"
    assert_decision "D-C47-1 attached-short foreign target -> ask" "ask" "$FOREIGN/repo"
    assert_reason_lacks "$OWNER/agents" "D-C47-1b no silent fallback to the owned cwd target"
    reset_env
    run_case "$FX_FOREIGN" "gh issue create -R$OWNER/agents --title x"
    assert_decision "D-C47-2 attached-short owned target -> silent allow" "silent"
    # D-C47-3 (the five-form unit for extractRepoSelectors, plus the extractRepoFlag
    # contrast that proves a cross-check would NOT have caught the attached form)
    # lives in tests/feature-forge-write-scan-extract/cases-2053-additive-exports.sh
    # section 2053-D/2053-B, where that module's SSOT coverage is.

    echo ""
    echo "=== E: cwd allowlist — an implicit target is only as good as the cwd ==="

    # A bare create takes its target from wherever the shell ends up. Anything
    # that can move, fork, or obscure the cwd makes that target unprovable.
    reset_env
    run_case "$FX_OWNED" "pushd $FX_FOREIGN && gh issue create --title x"
    assert_decision "E-1 pushd into a foreign checkout then bare create -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN && gh issue create --title x"
    assert_decision "E-2 cd into a foreign checkout then bare create -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "(gh issue create --title x)"
    assert_decision "E-3 bare create inside a subshell -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create --title x | tee out.txt"
    assert_decision "E-4 bare create in a pipeline -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "env -C $FX_FOREIGN gh issue create --title x"
    assert_decision "E-5 env -C relocates the cwd -> ask" "ask"

    # The counter-case: once the target is named explicitly, where the shell
    # stands no longer matters, so the same relocation must stay silent.
    reset_env
    run_case "$FX_OWNED" "pushd $FX_FOREIGN && gh issue create --repo $OWNER/agents --title x"
    assert_decision "E-6 relocated cwd but an explicit owned target -> silent allow" "silent"

    reset_env
    run_case "$FX_OWNED" "cd /tmp
gh issue create --title x"
    assert_decision "E-7 two-line cd + bare create from an owned cwd -> ask" "ask"

    # A payload with no cwd at all: the hook must not guess its own process cwd.
    reset_env
    run_case "-" "gh issue create --title x"
    assert_decision "E-8 payload without tool_input.cwd -> ask" "ask"

    echo ""
    echo "=== F: tool payload normalization — the same command in other shapes ==="

    reset_env
    run_tool_case "runCommands" "$FX_OWNED" "gh issue create --repo $FOREIGN/r --title x"
    assert_decision "F-1 runCommands payload with a foreign target -> ask" "ask"
    reset_env
    run_tool_case "runInTerminal" "$FX_OWNED" "gh issue create --repo $FOREIGN/r --title x"
    assert_decision "F-2 runInTerminal payload with a foreign target -> ask" "ask"

    # Several commands in one payload: each element is its own command line, and
    # a bare create among them cannot be tied to a proven cwd.
    reset_env
    run_tool_case "runCommands" "$FX_OWNED" "cd $FX_FOREIGN" "gh issue create --title x"
    assert_decision "F-3 two-element array ending in a bare create -> ask" "ask"

    reset_env
    run_tool_case "Read" "$FX_OWNED" "gh issue create --repo $FOREIGN/r"
    assert_decision "F-4 a non-command tool is passed through untouched" "silent"
    assert_probes "F-4b passThrough spends no probe budget" "api user" 0
}
