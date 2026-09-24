#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block J — the structural backstop: a forge write hidden inside a nested body,
# a quoted span, or a wrapper must reach "unresolved" (ask), never silent allow.
# J-12 (raw-spelling provenance) is a unit case and lives in cases-m-n.sh.

run_block_j() {
    echo ""
    echo "=== J-1: no false positives — talking about gh is not running gh ==="

    # This repo is full of text that mentions the command. If mere mention armed
    # the guard, every grep, commit, and cat here would prompt.
    j_pass() { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "silent"
               assert_probes "$1 [no probe spent]" "api user" 0; }
    j_ask()  { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "ask" "${3:-}"; }

    j_pass "J-1a a commit message that mentions the command" \
           'git commit -m "guard for gh issue create"'
    j_pass "J-1b echoing the command text" 'echo "gh api -X POST repos/x/y"'
    j_pass "J-1c grepping for the command text" 'rg "gh issue create" tests/'
    j_pass "J-1d cat of this very test file" \
           'cat tests/feature-2053-forge-target-ownership.sh'

    echo ""
    echo "=== J-2: RESOLVE set — an interpreter body is still a command line ==="

    j_ask "J-2a bash -c body, foreign target" \
          "bash -c \"gh issue create --repo $FOREIGN/x\""
    j_ask "J-2b sh -c body, bare create" "sh -c 'gh issue create'"
    j_ask "J-2c eval body, foreign target" "eval 'gh issue create --repo $FOREIGN/x'"
    j_ask "J-2d zsh -c body, bare create" "zsh -c 'gh issue create'"
    j_ask "J-2e here-string into sh" "sh <<< 'gh issue create'"
    # The pair that proves the ask above is about the TARGET, not about the mere
    # presence of an interpreter: same nesting, owned target, resolved cleanly.
    reset_env
    run_case "$FX_OWNED" "bash -c \"gh issue create --repo $OWNER/agents --title x\""
    assert_decision "J-2f bash -c body with an owned target -> silent allow" "silent"
    # SKIPPED: the mutation pair "with the nested-body layer disabled these all
    # pass through". Because: TL2 drives the hook as one process and cannot
    # switch an internal layer off. L3 gap: none — this is a unit-level mutation
    # probe, and cases-m-n.sh nestedBodyOf coverage is where it belongs.

    echo ""
    echo "=== J-3: multi-command bodies abandon resolution rather than guess ==="

    # Two commands in one body mean two potential targets. The contract is that
    # the guard REFUSES to resolve, not that it resolves the first one and hopes.
    reset_env
    run_case "$FX_OWNED" "bash -c \"cd $FX_FOREIGN && gh issue create --title x\""
    assert_decision "J-3a cd + create in one body -> ask" "ask" "multi-command-body"
    assert_reason_lacks "$OWNER/agents" "J-3b resolution was abandoned, not guessed"
    reset_env
    run_case "$FX_OWNED" "sh -c 'gh issue create --repo a/b; gh issue create --repo c/d'"
    assert_decision "J-3c two creates in one body -> ask" "ask" "multi-command-body"

    # J-3b (sharpest form): the FIRST command would prove fine. A guard that
    # stops at the first success never sees the second, unproven target.
    reset_env
    run_case "$FX_OWNED" "bash -c \"gh issue create --repo $OWNER/agents -t a; gh issue create -t b\""
    assert_decision "J-3d proven first + unproven second -> ask" "ask" "multi-command-body"
    reset_env
    run_case "$FX_OWNED" "bash -c \"gh issue create --repo $OWNER/agents -t a
gh issue create -t b\""
    assert_decision "J-3e same, split by an in-span newline" "ask" "quoted-newline-in-body"

    echo ""
    echo "=== J-4: a newline inside a quoted span is not a line break ==="

    # The one pin for "classify before folding": fold first and this body looks
    # like a single innocent command.
    reset_env
    run_case "$FX_OWNED" "bash -c \"cd $FX_FOREIGN
gh issue create --title x\""
    assert_decision "J-4 newline inside the body -> ask" "ask" "quoted-newline-in-body"

    echo ""
    echo "=== J-5: the mention gate keeps ordinary nested bodies quiet ==="

    j_pass "J-5a bash -c with no forge write" 'bash -c "cd /tmp && make test"'
    j_pass "J-5b a multi-line commit message" 'git commit -m "line1
line2"'
    j_pass "J-5c node -e with no forge write" "node -e 'console.log(1)'"

    echo ""
    echo "=== J-6: ansi-c spans — gated by POSITION, not by mention ==="

    # An ansi-c span can weld a command word out of escapes, so a span sitting in
    # an EXECUTION position is unresolved regardless of what it seems to say.
    j_ask "J-6a bash -c \$'...' with a foreign target" \
          "bash -c \$'gh issue create --repo $FOREIGN/x'" "ansic-span"
    j_ask "J-6b bash -c \$'cd ...\\ngh issue create'" \
          "bash -c \$'cd $FX_FOREIGN\\ngh issue create'" "ansic-span"
    # Deliberate false ask: no forge mention at all, but the span is in an
    # execution position. Pinned so nobody "fixes" it back into a mention gate.
    j_ask "J-6c bash -c \$'echo hi' -> ask even with no mention" \
          "bash -c \$'echo hi'" "ansic-span"
    # cmd0 welded out of escapes — the C35 regression pin.
    j_ask "J-6d \$'g\\x68' as the command word" \
          "\$'g\\x68' issue create --repo $FOREIGN/x" "ansic-span"
    j_ask "J-6e welded cmd0 behind xargs" "xargs \$'g\\x68' issue create" "ansic-span"
    j_ask "J-6f welded cmd0 behind timeout" "timeout 5 \$'gh' issue create" "ansic-span"
    j_ask "J-6g an ansi-c assignment in front of gh" \
          "env \$'GH_REPO=$FOREIGN/x' gh issue create" "ansic-span"

    # The other half of the position gate: a span used as DATA by an inert head
    # is ordinary shell quoting. These four are why the trigger is positional.
    j_pass "J-6h echo \$'a\\tb'" "echo \$'a\\tb'"
    j_pass "J-6i printf \$'%s\\n' x" "printf \$'%s\\n' x"
    j_pass "J-6j grep -P \$'\\t' f" "grep -P \$'\\t' f"
    j_pass "J-6k cut -d \$'\\t' -f1 f" "cut -d \$'\\t' -f1 f"

    # Heads that can execute their argument must NOT be on the inert allowlist.
    j_ask "J-6l sed with the e flag" "sed \$'s/a/b/e' f" "ansic-span"
    j_ask "J-6m awk with system()" "awk \$'BEGIN{system(\"x\")}' f" "ansic-span"
    j_ask "J-6n git -c" "git \$'-c' x" "ansic-span"
    j_ask "J-6o find -exec" "find . -name \$'x' -exec y \\;" "ansic-span"

    # Scope pin: a segment already claimed by the gh detector is resolved, so the
    # ansi-c layer never runs on it — a tab in a title is not a reason to ask.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title \$'a\\tb'"
    assert_decision "J-6p ansi-c title on a claimed, owned segment -> silent allow" "silent"

    echo ""
    echo "=== J-7 / J-8: quoting the guard cannot model, and here-string receivers ==="

    j_ask "J-7a here-string from a variable" "sh <<< \$CMD" "unmodeled-body-quoting"
    j_ask "J-7b backslash-escaped body words" 'sh -c gh\ issue\ create' "unmodeled-body-quoting"
    j_ask "J-7c nested double quotes in the body" \
          'bash -c "gh issue create --title \"a b\""' "unmodeled-body-quoting"
    j_ask "J-7d an unexpanded variable in the body" \
          'bash -c "gh issue create --repo $REPO"' "unmodeled-body-quoting"
    # A here-string is only a program when its receiver executes text.
    j_pass "J-8a here-string into jq is data" 'jq . <<< "$json"'
    j_ask  "J-8b here-string into sh is a program" "sh <<< 'gh issue create'"

    echo ""
    echo "=== J-9 / J-10 / J-11: other interpreters, missing bodies, peeled wrappers ==="

    j_ask "J-9a pwsh -Command with a foreign target" \
          "pwsh -Command \"gh issue create --repo $FOREIGN/x\"" "language-interpreter-body"
    # Deliberate false ask: the guard does not parse PowerShell, so an owned
    # target inside one is still unresolved. Pinned as intended behaviour.
    j_ask "J-9b pwsh -Command with an OWNED target is still ask" \
          "pwsh -Command \"gh issue create --repo $OWNER/agents\"" "language-interpreter-body"
    j_ask "J-9c node -e spawning gh" \
          "node -e 'require(\"child_process\").execSync(\"gh issue create\")'" \
          "language-interpreter-body"
    j_pass "J-9d node -e with no forge write" "node -e 'console.log(1)'"

    j_ask "J-10a bash -c with no body token" "bash -c" "body-missing"
    j_ask "J-10b nesting deeper than the depth cap" \
          "bash -c \"bash -c \\\"bash -c 'bash -c \\\\\\\"gh issue create\\\\\\\"'\\\"\"" "depth-cap"

    j_ask "J-11a env-wrapped bash -c, foreign target" \
          "env bash -c \"gh issue create --repo $FOREIGN/x\"" "wrapper-peeled-body"
    j_ask "J-11b env-wrapped bash -c, OWNED target is still ask" \
          "env bash -c \"gh issue create --repo $OWNER/agents/x\"" "wrapper-peeled-body"
    j_pass "J-11c env-wrapped bash -c with no forge write" 'env bash -c "cd /tmp && make"'
    # Contrast: peeling the wrapper leaves a plain gh command, which resolves.
    reset_env
    run_case "$FX_OWNED" "env gh issue create --repo $OWNER/agents --title x"
    assert_decision "J-11d env-wrapped gh with an owned target -> silent allow" "silent"

    echo ""
    echo "=== C32 / 4-4B / C24 regressions ==="

    # C32: the quoting style of the body must not decide the outcome. Both must
    # be pinned — dropping the pre-fold classification kills only the DQ side.
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN
bash -c \"gh issue create --repo $FOREIGN/x\""
    assert_decision "C32-1 two-line payload + double-quoted body -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN
sh -c 'gh issue create --repo $FOREIGN/x'"
    assert_decision "C32-2 two-line payload + single-quoted body -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "cd $FX_FOREIGN
bash -c \"gh issue create --repo $OWNER/agents\""
    assert_decision "C32-3 same shape with an owned target -> silent allow" "silent"

    # 4-4B: gh appearing at a non-head argv position behind an unmodelled runner.
    j_ask "4-4B-a uv run gh"     "uv run gh issue create --repo $FOREIGN/x"
    j_ask "4-4B-b timeout gh"    "timeout 30 gh issue create --repo $FOREIGN/x"
    j_ask "4-4B-c xargs gh"      "xargs gh issue create < f"
    j_ask "4-4B-d winpty gh"     "winpty gh issue create --repo $FOREIGN/x"

    # C24: known transparent wrappers peel cleanly, so an owned target stays quiet.
    reset_env
    run_case "$FX_OWNED" "nice gh issue create --repo $OWNER/agents --title x"
    assert_decision "C24-a nice-wrapped owned target -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "nohup gh issue create --repo $OWNER/agents --title x"
    assert_decision "C24-b nohup-wrapped owned target -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "command gh issue create --repo $OWNER/agents --title x"
    assert_decision "C24-c command-wrapped owned target -> silent allow" "silent"
    # The back side: an unclassifiable wrapper option fails closed.
    j_ask "C24-d env with an unknown option" \
          "env -Z val gh issue create --repo $OWNER/agents"

    # A command line the IR cannot parse is, by definition, unmodelled.
    j_ask "J-parsefail unbalanced quoting -> ask" 'gh issue create --title "unterminated'

    unset -f j_pass j_ask
}
