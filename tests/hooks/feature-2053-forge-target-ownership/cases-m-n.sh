#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks M (pure-function units, incl. J-12 raw-spelling provenance) and
# N (the sanctioned forms this repository itself runs).

run_block_m_n() {
    echo ""
    echo "=== M: budget, proof, and gh-api argv units ==="

    # The budget must shrink as it is spent and refuse rather than borrow: a
    # probe allowed to start with no time left is how the 10s hook cap is blown.
    unit_expr "M-1a probeTimeout shrinks as the budget is spent" "true" "budget.js" \
        '(function(){var b=m.createBudget();var t1=m.probeTimeout(b,2500);b.spentMs=(b.spentMs||0)+2000;var t2=m.probeTimeout(b,2500);return t2 < t1;})()'
    unit_expr "M-1b probeTimeout returns null once the reserve is reached" "true" "budget.js" \
        '(function(){var b=m.createBudget();b.spentMs=999999;return m.probeTimeout(b,2500) === null;})()'
    unit_expr "M-1c a probe is never granted less than the minimum" "true" "budget.js" \
        '(function(){var b=m.createBudget();var t=m.probeTimeout(b,2500);return t === null || t >= 250;})()'

    # Every failure of the proof path means "not proven", never "assume yes".
    unit_expr "M-2a proveOwned returns false when the probe throws" "false" "prove-ownership.js" \
        'm.proveOwned({ owner: "o", repo: "r" }, { spawn: function(){ throw new Error("boom"); } })'
    unit_expr "M-2b proveOwned returns false on a null budget" "false" "prove-ownership.js" \
        'm.proveOwned({ owner: "o", repo: "r" }, null)'
    unit_expr "M-3a repoFacts is null on a non-2xx response" "null" "prove-ownership.js" \
        'm.repoFacts({ status: 404, stdout: "" })'
    unit_expr "M-3b repoFacts is null on an empty body" "null" "prove-ownership.js" \
        'm.repoFacts({ status: 200, stdout: "" })'
    unit_expr "M-3c repoFacts is null on an unparsable body" "null" "prove-ownership.js" \
        'm.repoFacts({ status: 200, stdout: "<html>" })'

    # The argv scanner decides which token is an endpoint and which is a flag's
    # value; mistaking one for the other is how a foreign endpoint hides.
    unit_expr "M-4a a value-taking flag consumes its value" '"repos/o/r/issues"' "gh-api-argv.js" \
        'm.scanGhApiFlags(["-H","Accept: x","repos/o/r/issues"]).endpoint'
    unit_expr "M-4b attached short -XPOST is read as a method" '"POST"' "gh-api-argv.js" \
        '(function(){var f=m.scanGhApiFlags(["-XPOST","repos/o/r/issues"]).flags.filter(function(x){return x.flag==="-X";});return f[0] && f[0].value;})()'
    unit_expr "M-4c attached long --method=POST is read as a method" '"POST"' "gh-api-argv.js" \
        '(function(){var f=m.scanGhApiFlags(["--method=POST","repos/o/r/issues"]).flags.filter(function(x){return x.flag==="--method";});return f[0] && f[0].value;})()'
    unit_expr "M-4d an unknown flag makes the scan ambiguous" "true" "gh-api-argv.js" \
        'm.scanGhApiFlags(["--unknown-flag","x","repos/o/r/issues"]).ambiguous === true'
    # The write/read classification itself is the shared library's, not a copy.
    assert_source_has "M-4e gh-api-argv.js imports isGhApiWriteFromFlags" \
        "gh-api-argv.js" "isGhApiWriteFromFlags"

    echo ""
    echo "=== M: nested-commands units ==="

    unit_expr "M-5a a newline inside quotes is not a line break" "1" "nested-commands.js" \
        'm.normalizeToLines("echo \"a\\nb\"").lines.length'
    unit_expr "M-5b a real newline is a line break" "2" "nested-commands.js" \
        'm.normalizeToLines("echo a\necho b").lines.length'
    # Folding must not eat the body: a double-quoted span collapsing to "" is the
    # bug this pins — the text is what later layers classify.
    unit_expr "M-5c quoted text survives folding byte-for-byte" "true" "nested-commands.js" \
        '(function(){var s=JSON.stringify(m.normalizeToLines("bash -c \"cd x\\ngh issue create\"").lines);return s.indexOf("cd x") !== -1 && s.indexOf("gh issue create") !== -1;})()'
    unit_expr "M-5d a heredoc body line is retained" "true" "nested-commands.js" \
        '(function(){var s=JSON.stringify(m.normalizeToLines("sh <<EOF\\ngh issue create\\nEOF").lines);return s.indexOf("gh issue create") !== -1;})()'
    unit_expr "M-5e a single-line input still runs the whole pipeline" "true" "nested-commands.js" \
        '(function(){var r=m.normalizeToLines("echo hi");return r.ok === true && r.lines.length === 1;})()'
    unit_expr "M-5f any failed stage makes the whole input unresolved" "false" "nested-commands.js" \
        'm.normalizeToLines("sh <<< $CMD").ok'

    unit_expr "M-6a nestedBodyOf has exactly three outcome kinds" "true" "nested-commands.js" \
        '["none","resolved","unresolved"].indexOf(m.nestedBodyOf({ cmd0: "echo", argv: ["hi"], argvRaw: ["hi"] }).kind) !== -1'
    unit_expr "M-6b an interpreter body resolves to a de-quoted single command" '"gh issue create"' \
        "nested-commands.js" 'm.nestedBodyOf({ cmd0: "bash", argv: ["-c","gh issue create"], argvRaw: ["-c","\x27gh issue create\x27"] }).body'
    assert_source_has "M-6c nested-commands.js imports MAX_NESTED_SCAN_DEPTH" \
        "nested-commands.js" "MAX_NESTED_SCAN_DEPTH"

    # mentionsForgeWrite works on raw text and is deliberately generous: a commit
    # message that quotes the command matches, and the later layers decide.
    unit_expr "M-7a mentionsForgeWrite finds a nested create" "true" "nested-commands.js" \
        'm.mentionsForgeWrite("bash -c \"gh issue create\"")'
    unit_expr "M-7b mentionsForgeWrite is false for an unrelated body" "false" "nested-commands.js" \
        'm.mentionsForgeWrite("bash -c \"cd x && make\"")'
    unit_expr "M-7c mentionsForgeWrite is true inside a commit message (by design)" "true" \
        "nested-commands.js" 'm.mentionsForgeWrite("git commit -m \"about gh issue create\"")'

    echo ""
    echo "=== M: the reason-code registry ==="

    # The reasons are the user-visible half of this guard. They are frozen so an
    # entry cannot invent a code that no documentation explains.
    unit_expr "M-8a REASONS is frozen" "true" "reasons.js" 'Object.isFrozen(m.REASONS)'
    unit_expr "M-8b REASONS holds exactly 11 codes" "11" "reasons.js" 'Object.keys(m.REASONS).length'
    unit_expr "M-8c every code is reachable from this test file" "true" "reasons.js" \
        '(function(){var want=["multi-command-body","quoted-newline-in-body","ansic-span","unmodeled-body-quoting","body-missing","depth-cap","language-interpreter-body","wrapper-peeled-body","command-substitution-body","auth-context-change","unrecognized-wrapper-head"];var have=Object.keys(m.REASONS).map(function(k){return m.REASONS[k];}).concat(Object.keys(m.REASONS));return want.every(function(w){return have.indexOf(w) !== -1;});})()'
    # Reached by: J-3 / J-4 / J-6 / J-7 / J-10a / J-10b / J-9 / J-11 / P-1 / Q-1 / R-1.
    assert_source_has "M-8d the entry imports REASONS instead of spelling codes inline" \
        "../confirm-forge-target-ownership.js" "reasons"

    echo ""
    echo "=== J-12: raw spelling is the evidence; normalized argv has lost it ==="

    # Whether a body was single- or double-quoted decides whether it can be
    # modelled, so the layers must read the RAW spelling, not the de-quoted argv.
    assert_source_has "J-12a nested-commands.js reads argvRaw" "nested-commands.js" "argvRaw"
    assert_source_has "J-12b nested-commands.js reads redirects[].targetRaw" \
        "nested-commands.js" "targetRaw"
    # SKIPPED: asserting that {...seg.redirects[0]} / JSON.stringify() drop the
    # raw spelling. Because: that is a property of the IR builder in hooks/lib,
    # not of this guard, and belongs to the IR module's own unit coverage.
    # L3 gap: none — it is unit-level, not environment-level.

    echo ""
    echo "=== N: the sanctioned forms this repository itself runs ==="

    # The only mandatory regression: the repo's own issue-filing path must not
    # start prompting. If it does, the guard has failed the people it protects.
    reset_env
    run_case "$FX_OWNED" "ISSUE_CREATE_SKILL=1 gh issue create --title x --body y"
    assert_decision "N-1 ISSUE_CREATE_SKILL=1 gh issue create -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "MSYS_NO_PATHCONV=1 gh issue create --title x --body y"
    assert_decision "N-2 MSYS_NO_PATHCONV=1 gh issue create -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "ISSUE_CREATE_SKILL=1 MSYS_NO_PATHCONV=1 gh issue create --title x"
    assert_decision "N-3 both sanctioned assignments together -> silent allow" "silent"
    # A proxy variable changes where the request goes, so it is not sanctioned.
    reset_env
    run_case "$FX_OWNED" "HTTPS_PROXY=http://p:8080 gh issue create --title x"
    assert_decision "N-4 HTTPS_PROXY redirects the request -> ask" "ask"
    # GH_TOKEN=... gh issue create -> ask is pinned once, by Q-1.
}
