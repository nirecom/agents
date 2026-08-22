#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks O2 (gh subcommand resolution, C46) and P (command substitution, C48).

run_block_o2_p() {
    echo ""
    echo "=== O2: the subcommand is not always at argv[0] ==="

    # gh/cobra accept persistent flags before, between, and after the subcommand
    # words. A fixed-position read of argv[0]/argv[1] misses every form below,
    # and a missed form is a silent allow — the same bypass class as #1296.
    o_ask() { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "ask"; }

    o_ask "O2-1 -R before the subcommand" \
          "gh -R $FOREIGN/repo issue create --title x"
    o_ask "O2-2 --repo before the subcommand" \
          "gh --repo $FOREIGN/repo issue create --title x"
    o_ask "O2-3 attached short before the subcommand" \
          "gh -R$FOREIGN/repo issue create --title x"
    o_ask "O2-4 -R between the two subcommand words" \
          "gh issue -R $FOREIGN/repo create --title x"
    o_ask "O2-5 --repo=<v> before the subcommand" \
          "gh --repo=$FOREIGN/repo issue create --title x"

    # Contrast: resolving the subcommand correctly must not widen what is in
    # scope — only issue CREATE is, and only when the target is unproven.
    reset_env
    run_case "$FX_OWNED" "gh -R $OWNER/agents issue create --title x"
    assert_decision "O2-6 -R with an owned target -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "gh issue list -R $FOREIGN/x"
    assert_decision "O2-7 issue list is a read -> passThrough" "silent"
    assert_probes "O2-7b issue list spends no probe" "api user" 0
    reset_env
    run_case "$FX_OWNED" "gh -R $FOREIGN/x pr view 1"
    assert_decision "O2-8 pr view is a read -> passThrough" "silent"
    assert_probes "O2-8b pr view spends no probe" "api user" 0

    # Unit: the subcommand words each form resolves to.
    unit_expr "O2-9a ghSubWords(-R v issue create)" '"issue,create"' "detect.js" \
        'm.ghSubWords(["-R","o/r","issue","create"]).slice(0,2).join(",")'
    unit_expr "O2-9b ghSubWords(--repo=v issue create)" '"issue,create"' "detect.js" \
        'm.ghSubWords(["--repo=o/r","issue","create"]).slice(0,2).join(",")'
    unit_expr "O2-9c ghSubWords(-Rv issue create)" '"issue,create"' "detect.js" \
        'm.ghSubWords(["-Ro/r","issue","create"]).slice(0,2).join(",")'
    unit_expr "O2-9d ghSubWords(issue -R v create)" '"issue,create"' "detect.js" \
        'm.ghSubWords(["issue","-R","o/r","create"]).slice(0,2).join(",")'
    # An unknown global flag must not be over-skipped into swallowing `issue`.
    unit_expr "O2-9e an unknown flag does not swallow the subcommand" '"issue,create"' \
        "detect.js" 'm.ghSubWords(["--unknown","x","issue","create"]).filter(w => w === "issue" || w === "create").join(",")'
    # The skip table itself is shared, not transcribed.
    assert_source_has "O2-10 detect.js imports resolveGhSubArgv rather than copying it" \
        "detect.js" "resolveGhSubArgv"

    unset -f o_ask

    echo ""
    echo "=== P: command substitution — the inner command really runs ==="

    # `echo "$(gh issue create ...)"` executes the inner command; cmd0 is echo,
    # so neither the gh detector nor the argv-position scan sees it.
    reset_env
    run_case "$FX_OWNED" "echo \"\$(gh issue create --repo $FOREIGN/repo --title x)\""
    assert_decision "P-1 \$(...) inside double quotes -> ask" "ask" "command-substitution-body"
    reset_env
    run_case "$FX_OWNED" "echo \`gh issue create --repo $FOREIGN/repo\`"
    assert_decision "P-2 backtick substitution -> ask" "ask" "command-substitution-body"

    # P-3: the outer command proves fine. A guard that stops once a line is
    # claimed never inspects the substitution riding along with it.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents/x --title \"\$(gh issue create --repo $FOREIGN/y)\""
    assert_decision "P-3 substitution inside a claimed, provable line -> ask" "ask" \
        "command-substitution-body"

    # P-4: substitutions are everywhere in ordinary shell use; only ones that
    # actually contain a forge write may ask.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title \"\$(date)\""
    assert_decision "P-4a a harmless substitution in an owned create -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "echo \"\$(ls)\""
    assert_decision "P-4b echo \$(ls) -> passThrough" "silent"
    assert_probes "P-4b2 no probe spent" "api user" 0
    # Single quotes do not substitute, so this text never executes.
    reset_env
    run_case "$FX_OWNED" "echo '\$(gh issue create --repo $FOREIGN/x)'"
    assert_decision "P-4c single-quoted \$(...) is literal text -> passThrough" "silent"
    assert_probes "P-4c2 no probe spent" "api user" 0

    # P-5: when the extractor recovers fewer bodies than there are openers, the
    # line is under-analysed — fall back to the line mention, do not assume safe.
    reset_env
    run_case "$FX_OWNED" "echo \"\$(f \$(x) gh issue create --repo $FOREIGN/y)\""
    assert_decision "P-5 nested openers exceed recovered bodies -> ask" "ask"

    # P-6 units.
    assert_source_has "P-6a substitutionBodiesOf reuses extractSubstitutionContents" \
        "nested-commands.js" "extractSubstitutionContents"
    unit_expr "P-6b a single-quoted opener is not counted" "0" "nested-commands.js" \
        'm.substitutionBodiesOf("echo \x27$(gh issue create)\x27").openers'
    unit_expr "P-6c an ansi-c-quoted opener is not counted" "0" "nested-commands.js" \
        'm.substitutionBodiesOf("echo $\x27$(gh issue create)\x27").openers'
    unit_expr "P-6d one real opener yields one body" "true" "nested-commands.js" \
        '(function(){var r=m.substitutionBodiesOf("echo \"$(gh issue create)\"");return r.openers === 1 && r.bodies.length === 1;})()'
    unit_expr "P-6e an opener/body mismatch is observable" "true" "nested-commands.js" \
        '(function(){var r=m.substitutionBodiesOf("echo \"$(f $(x) gh issue create)\"");return r.openers > r.bodies.length;})()'
}
