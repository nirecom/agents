#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/scan-core-node/byte-and-cli-edges.sh
# Tests: hooks/lib/comment-block-scan.js, bin/review-comment-block-size.d/scan-cli.js
# Tags: comment-block-size, parser, node, ssot, scope:issue-specific, scope:feature-1894, layer:TL2
# Sections N5/N6 of ../scan-core-node.sh, split out to keep that file under the
# 500-line HARD limit (rules/coding/file-split.md). Sourced, not run: helpers
# and NS_* state come from the parent case file and the dispatcher.
# N5 — byte/line edges the awk core handled implicitly. The port moved line
# splitting from awk's record separator to text.split(/\n/); every shape below
# is one where the two could disagree with no recognition rule being wrong.
echo ""
echo "=== N5: line-splitting and byte-level edges ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
    # Empty file: no runs, no crash, and no phantom trailing line.
    : > "$NS_DIR/probe.txt"
    _p="$(ns_path "$NS_DIR/probe.txt")"
    assert_eq "N5/empty-file-longest" "none" "$(nsv longest 10 "$_p")"
    assert_eq "N5/empty-file-count" "0" "$(nsv count 10 "$_p")"

    # A file that is a single newline: one empty line, still no run.
    printf '\n' > "$NS_DIR/probe.txt"
    assert_eq "N5/lone-newline" "none" "$(nsv longest 10 "$_p")"

    # No trailing newline: the final run must still be flushed. awk got this for
    # free; split() does not.
    { for i in $(seq 1 10); do echo "#c$i"; done; printf '#c11'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/no-trailing-newline-flushes" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/no-trailing-newline-span" "1-11:11" "$(nsv runs 10 "$_p")"

    # Trailing newline must NOT add a phantom 12th line to the run.
    { for i in $(seq 1 11); do echo "#c$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/trailing-newline-no-phantom-line" "1-11:11" "$(nsv runs 10 "$_p")"

    # CRLF: the \r must be stripped before marker recognition, or "*/" and "* "
    # stop matching and a block silently runs to EOF.
    { for i in $(seq 1 11); do printf '// c%s\r\n' "$i"; done; printf 'x=1\r\n'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/crlf-longest" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/crlf-span" "1-11:11" "$(nsv runs 10 "$_p")"

    # CRLF inside a block comment: the close marker carries the \r.
    { printf '/*a\r\n'; for i in $(seq 1 9); do printf '* c%s\r\n' "$i"; done; printf '*/\r\n'; printf 'x=1\r\n'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/crlf-block-closes" "11" "$(nsv longest 10 "$_p")"

    # A leading BOM sits in front of the first marker: whatever the module
    # decides, it decides for line 1 only — the run must not vanish.
    { printf '\xEF\xBB\xBF'; for i in $(seq 1 12); do echo "#c$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/bom-does-not-swallow-the-run" "ok" "$(nsv invariants 10 "$_p")"
    if [ "$(nsv count 10 "$_p")" -ge 1 ]; then
        pass "N5/bom-run-still-detected"
    else
        fail "N5/bom-run-still-detected" "BOM on line 1 suppressed a 12-line run entirely"
    fi

    # Invalid UTF-8 becomes U+FFFD; every marker is ASCII, so the verdict must
    # be unaffected — and the module must not throw on a binary-ish file.
    { for i in $(seq 1 11); do printf '# c%s \xC3\x28\xFF\n' "$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/invalid-utf8-longest" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/invalid-utf8-no-throw" "0" "$(ns_rc longest 10 "$_p")"

    # NUL bytes mid-line: same requirement.
    { for i in $(seq 1 11); do printf '# c%s\000tail\n' "$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/nul-bytes-longest" "11" "$(nsv longest 10 "$_p")"

    # Lone CR as the only separator (classic-Mac endings): NOT a line break for
    # split(/\n/), so this is one very long line and cannot be an 11-line run.
    { for i in $(seq 1 11); do printf '# c%s\r' "$i"; done; printf '\n'; } > "$NS_DIR/probe.txt"
    assert_eq "N5/lone-cr-is-not-a-line-break" "none" "$(nsv longest 10 "$_p")"

    # One enormous line: guards against a quadratic or stack-recursive splitter.
    # 2 MB on a single line, wrapped in a run that must still be found.
    {
        for i in $(seq 1 5); do echo "#c$i"; done
        printf '# '
        head -c 2000000 /dev/zero | tr '\0' 'x'
        printf '\n'
        for i in $(seq 1 5); do echo "#d$i"; done
    } > "$NS_DIR/probe.txt"
    assert_eq "N5/huge-single-line-longest" "11" "$(nsv longest 10 "$_p")"
    assert_eq "N5/huge-single-line-no-timeout" "0" "$(ns_rc longest 10 "$_p")"

    # Whitespace-only lines are neutral: they bridge a top-level run rather than
    # terminating it, and a line of only tabs must be the exact same neutral
    # line as a line of only spaces (C1 covers the space-only side).
    { for i in $(seq 1 6); do echo "#c$i"; done; printf '\t\t\n'; for i in $(seq 1 6); do echo "#d$i"; done; } > "$NS_DIR/probe.txt"
    assert_eq "N5/tab-only-line-bridges-run" "12" "$(nsv longest 10 "$_p")"
fi

# N6 — scan-cli.js, the bash-facing adapter. The CLI parses this stdout with
# the reader it used for awk, so the line format is a contract.
echo ""
echo "=== N6: scan-cli.js stdout/rc contract ==="
if [ "$NS_HAVE_NODE" = "1" ]; then
    # Sets NS_OUT / NS_ERR / NS_RC in the CURRENT shell — never call it inside
    # $( ), or the exit code is lost with the subshell.
    NS_OUT=""
    ns_cli() {
        local t="$1" f="$2" errf="$NS_DIR/clierr.txt"
        NS_RC=0
        run_with_timeout 30 node "$NS_CLI_P" --threshold "$t" <"$f" \
            >"$NS_DIR/cliout.txt" 2>"$errf" || NS_RC=$?
        NS_OUT="$(cat "$NS_DIR/cliout.txt" 2>/dev/null || true)"
        NS_ERR="$(cat "$errf" 2>/dev/null || true)"
    }

    render_spec "x=1 //a*11 x=1 //b*5 x=1 //c*12" > "$NS_DIR/cli.txt"
    ns_cli 10 "$NS_DIR/cli.txt"
    assert_eq "N6/rc-zero-with-findings" "0" "$NS_RC"
    assert_eq "N6/line-format" "2-12:11,20-31:12" \
        "$(printf '%s\n' "$NS_OUT" | awk 'NF{printf "%s%s-%s:%s", (n++?",":""), $1, $2, $3}')"
    assert_eq "N6/nothing-on-stderr" "" "$NS_ERR"

    render_spec "//a*10 x=1" > "$NS_DIR/cli.txt"
    ns_cli 10 "$NS_DIR/cli.txt"
    assert_eq "N6/rc-zero-without-findings" "0" "$NS_RC"
    assert_eq "N6/no-output-without-findings" "" "${NS_OUT//[[:space:]]/}"

    # rc 2 is the usage error. rc 1 is RESERVED for the blocking verdict and
    # this adapter must never return it — a bash caller that treated 1 as
    # "scanner failed" would fail open on every future block.
    : > "$NS_DIR/cli.txt"
    ns_cli "" "$NS_DIR/cli.txt"
    assert_eq "N6/missing-threshold-is-rc2" "2" "$NS_RC"
    ns_cli "abc" "$NS_DIR/cli.txt"
    assert_eq "N6/non-numeric-threshold-is-rc2" "2" "$NS_RC"

    NS_RC=0
    run_with_timeout 30 node "$NS_CLI_P" </dev/null >/dev/null 2>&1 || NS_RC=$?
    assert_eq "N6/no-args-is-rc2" "2" "$NS_RC"
fi
