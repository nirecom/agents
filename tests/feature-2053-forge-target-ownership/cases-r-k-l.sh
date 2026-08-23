#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks R (interpreters behind unknown wrappers, C53), K (out of scope),
# L (marker non-honouring, remote shapes, forks).

run_block_r_k_l() {
    echo ""
    echo "=== R: an interpreter behind a wrapper nobody enumerated ==="

    # timeout / xargs / docker are not in the wrapper table, so the head is not
    # peeled; and the interpreter's program is one quoted token, so the argv
    # scan does not see gh either. The trigger is therefore the POSITION of an
    # interpreter word — no wrapper names are enumerated, by design.
    r_ask()  { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "ask" "${3:-}"; }
    r_pass() { reset_env; run_case "$FX_OWNED" "$2"; assert_decision "$1" "silent"
               assert_probes "$1 [no probe spent]" "api user" 0; }

    r_ask "R-1 timeout + bash -c, foreign target" \
          "timeout 5 bash -c \"gh issue create --repo $FOREIGN/x\"" "unrecognized-wrapper-head"
    # The pair: without the wrapper the same body is caught by the nested-body
    # layer, so R-1's ask is attributable to the unrecognized head, not luck.
    reset_env
    run_case "$FX_OWNED" "bash -c \"gh issue create --repo $FOREIGN/x\""
    assert_decision "R-1b the unwrapped form is caught by the body layer" "ask"
    assert_reason_lacks "unrecognized-wrapper-head" "R-1c and for a different reason"

    r_ask "R-2a xargs + sh -c" "xargs sh -c 'gh issue create --repo $FOREIGN/x'" \
          "unrecognized-wrapper-head"
    r_ask "R-2b env -S with an inline program" "env -S 'gh issue create --repo $FOREIGN/x'" \
          "unrecognized-wrapper-head"
    r_ask "R-2c docker run + bash -c" \
          "docker run img bash -c \"gh api -X POST repos/$FOREIGN/r/issues -f title=x\"" \
          "unrecognized-wrapper-head"

    # R-3: the body is never resolved, so owning the target cannot help. This is
    # a deliberate false ask, pinned so it is not "fixed" by resolving bodies.
    r_ask "R-3 timeout + bash -c with an OWNED target is still ask" \
          "timeout 5 bash -c \"gh issue create --repo $OWNER/agents/x\"" \
          "unrecognized-wrapper-head"

    r_pass "R-4a timeout + bash -c with no forge write" 'timeout 5 bash -c "cd /tmp && make"'
    r_pass "R-4b xargs + sh -c with no forge write" "xargs sh -c 'rm -f x'"
    r_pass "R-4c timeout + node -e with no forge write" "timeout 5 node -e 'console.log(1)'"

    # R-5: a trigger of "unknown command word + quoted argument" would ask on all
    # three of these. Anchoring on the interpreter word is why they stay quiet.
    r_pass "R-5a commit message mentioning the command" \
           'git commit -m "guard for gh issue create"'
    r_pass "R-5b grep for the command text" 'rg "gh issue create" tests/'
    r_pass "R-5c echo of the command text" 'echo "gh api -X POST repos/x/y"'

    # R-6: a mention-evading ansi-c body is caught by the position gate instead,
    # so the two layers cover each other.
    r_ask "R-6 timeout + bash -c \$'...' is caught as an ansi-c span" \
          "timeout 5 bash -c \$'gh issue create --repo $FOREIGN/x'" "ansic-span"

    # R-7 units: no double counting, and the interpreter list is imported.
    unit_expr "R-7a no fire on a segment whose body already resolved" "false" \
        "detect.js" 'm.unrecognizedWrapperHead({ claimed: true, bodyState: "resolved" })'
    unit_expr "R-7b no fire on a segment whose body is already unresolved" "false" \
        "detect.js" 'm.unrecognizedWrapperHead({ claimed: false, bodyState: "unresolved" })'
    unit_expr "R-7c no fire on a segment the argv-position scan already counted" "false" \
        "detect.js" 'm.unrecognizedWrapperHead({ claimed: false, bodyState: "none", argvScanCounted: true })'
    assert_source_has "R-7d detect.js imports interpreterKindOfWord rather than listing names" \
        "detect.js" "interpreterKindOfWord"

    unset -f r_ask r_pass

    echo ""
    echo "=== K: out of scope — the guard stays out of the way ==="

    reset_env
    run_case "$FX_OWNED" "gh issue list"
    assert_decision "K-1 gh issue list -> passThrough" "silent"
    assert_probes "K-1b no probe spent" "api user" 0
    reset_env
    run_case "$FX_OWNED" "gh pr create --title x --body y"
    assert_decision "K-2 gh pr create is outside the approved scope -> passThrough" "silent"
    assert_probes "K-2b no probe spent" "api user" 0
    reset_env
    run_case "$FX_OWNED" "git commit -m x"
    assert_decision "K-3 git commit -> passThrough" "silent"

    # Malformed stdin must not crash the hook: a crash in PreToolUse is either a
    # hard block or a silent bypass, and neither is an acceptable failure mode.
    reset_env
    : > "$BASE/in.json"; : > "$GH_LOG"; _dispatch
    assert_decision "K-4 empty stdin -> silent, no crash" "silent"
    reset_env
    printf 'not json at all' > "$BASE/in.json"; : > "$GH_LOG"; _dispatch
    assert_decision "K-5 non-JSON stdin -> silent, no crash" "silent"

    echo ""
    echo "=== L: markers, remote shapes, forks ==="

    # This guard protects a boundary the user did not delegate, so the workflow
    # escape hatches must NOT switch it off.
    reset_env
    run_case "$FX_FOREIGN" "echo warmup"
    : > "$CLAUDE_WORKFLOW_DIR/$SID.workflow-off"
    resume_case "$FX_FOREIGN" "gh issue create --title x"
    assert_decision "L-1 a .workflow-off marker does not silence the guard -> ask" "ask"
    rm -f "$CLAUDE_WORKFLOW_DIR/$SID.workflow-off"

    reset_env
    run_case "$FX_TWO" "gh issue create --title x"
    assert_decision "L-2 two remotes make the implicit target ambiguous -> ask" "ask"
    reset_env
    run_case "$FX_RESOLVED" "gh issue create --title x"
    assert_decision "L-3 gh-resolved pointing at another repo -> ask" "ask"

    # A fork's origin is owned by the caller, but `gh issue create` in a fork
    # files against the PARENT by default — a repo the caller does not own.
    reset_env; add_env "GH_STUB_FORK=true"; add_env "GH_STUB_PARENT=$FOREIGN/upstream"
    run_case "$FX_FORK" "gh issue create --title x"
    assert_decision "L-4 a fork checkout -> ask, naming the parent" "ask" "$FOREIGN/upstream"
    reset_env; add_env "GH_STUB_FORK=false"
    run_case "$FX_FORK" "gh issue create --title x"
    assert_decision "L-5 a non-fork owned checkout -> silent allow" "silent"
    reset_env; add_env "GH_STUB_EXIT=1"
    run_case "$FX_FORK" "gh issue create --title x"
    assert_decision "L-6 fork status unknown (non-zero exit) -> ask" "ask"
    reset_env; add_env "GH_STUB_SLEEP=30"
    run_case "$FX_FORK" "gh issue create --title x"
    assert_decision "L-7 fork status unknown (timeout) -> ask" "ask"
    reset_env
    run_case "$FX_NOREMOTE" "gh issue create --title x"
    assert_decision "L-8 no origin at all -> ask" "ask"
}
