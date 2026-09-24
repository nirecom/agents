#!/usr/bin/env bash
# Part of tests/fix-1780-round12-parser-unit-tables.sh (rules/coding/file-split.md).
# Section M - MUTATION EVIDENCE for every regex constant the tables above are
# keyed on. Sourced by the parent, which owns _expand(), the counters and the
# SANDBOX / PROBE / MUTATE paths.

# ===========================================================================
# Section M — MUTATION EVIDENCE (skills/_shared/test-design/parser-regex-tests.md).
#
# Each row names ONE regex constant, the row above that is keyed on it, the value
# that row produces normally, and the DIFFERENT value it must produce once the
# constant is replaced with the never-matching `/(?!)/`. A constant whose mutant
# leaves the value unchanged is not covered by this suite, and the assertion fails
# by name rather than passing in silence.
#
# The mutation runs against a COPY of hooks/ in a temp dir — the real tree is
# never written to. Both regex forms are covered: single-line `const NAME = /re/;`
# (GLOB_METACHAR_RE, ASSIGN_WORD_RE) and multi-line `new RegExp(String.raw`…`)`
# (everything else), the second of which bin/mutation-probe.sh cannot reach.
#
# Table: name|const|file|fn|input|want-normal|want-mutant  (own reader, since the
# 7 columns and the mandatory pairing differ from run_table's contract).
# ===========================================================================
run_M_mutation_evidence() {
    if [ ! -f "$MUTATE" ]; then
        fail "M mutate.js MISSING at $MUTATE - no mutation evidence for any constant"
        return
    fi
    if ! command -v cp >/dev/null 2>&1; then skip "M cp unavailable"; return; fi

    local work="$SANDBOX/mut"
    local name konst file fn input wnorm wmut tblrow got_n got_m mres
    local killed=0 total=0
    while IFS='|' read -r name konst file fn input wnorm wmut; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
        konst="$(printf '%s' "$konst" | sed 's/^ *//; s/ *$//')"
        file="$(printf '%s' "$file" | sed 's/^ *//; s/ *$//')"
        fn="$(printf '%s' "$fn" | sed 's/^ *//; s/ *$//')"
        wnorm="$(printf '%s' "$wnorm" | sed 's/^ *//; s/ *$//')"
        wmut="$(printf '%s' "$wmut" | sed 's/^ *//; s/ *$//')"
        total=$((total + 1))

        rm -r -f "$work" 2>/dev/null
        mkdir -p "$work" || { fail "M $konst could not create the mutation workdir"; continue; }
        cp -r "$AGENTS_DIR/hooks" "$work/hooks" 2>/dev/null || { fail "M $konst could not copy hooks/"; continue; }

        tblrow="$(_expand "row|$wnorm|$fn|$input")"
        got_n=$(printf '%s\n' "$tblrow" | "$RWT" 30 node "$(node_path "$PROBE")" "$(node_path "$work")" 2>&1 \
            | awk -F'\t' '$1 == "row" { print $2; exit }')

        mres=$("$RWT" 20 node "$(node_path "$MUTATE")" "$(node_path "$work/$file")" "$konst" 2>&1)
        if [ "$mres" != "ok" ]; then
            fail "M $konst could not be mutated in $file ($mres) - the constant may have been renamed or removed"
            continue
        fi
        got_m=$(printf '%s\n' "$tblrow" | "$RWT" 30 node "$(node_path "$PROBE")" "$(node_path "$work")" 2>&1 \
            | awk -F'\t' '$1 == "row" { print $2; exit }')

        assert_eq "M $name unmutated ($konst)" "$(_expand "$wnorm")" "$got_n"
        assert_eq "M $name MUTATED to /(?!)/ ($konst) - the row is keyed on this constant" \
            "$(_expand "$wmut")" "$got_m"
        [ "$got_n" != "$got_m" ] && killed=$((killed + 1))
    done <<'TABLE'
M-glob   | GLOB_METACHAR_RE            | hooks/lib/basename-glob-normalize.js                            | hasglob | s1@MK1@?                | true  | false
M-rocmd  | READ_ONLY_ARG_COMMAND_RE    | hooks/block-clearance-token-write/bash-scan/argv-scan.js          | rocmd   | cat                     | true  | false
M-lesslog| LESS_LOG_OPT_RE             | hooks/block-clearance-token-write/bash-scan/argv-scan.js          | roinv   | less -o /wf/s1@MK@      | false | true
M-varref | VAR_REF_RE                  | hooks/block-clearance-token-write/bash-scan/argv-scan.js          | varref  | $A                      | A     | -
M-pwsh   | PWSH_ENV_ASSIGN_ONLY_RE     | hooks/block-clearance-token-write/bash-scan/assignment-text.js    | pwshassign | $env:A=x             | true  | false
M-interp | INTERPRETER_RE              | hooks/block-clearance-token-write/interpreter-scan.js             | interpre | node -e "x"            | true  | false
M-bodyfirst | BODY_FIRST_INTERPRETER_RE | hooks/block-clearance-token-write/interpreter-scan.js            | bodyfirst | awk 'BEGIN{print}'    | true  | false
M-inlineflag | INLINE_PROGRAM_FLAG_RE  | hooks/block-clearance-token-write/interpreter-scan.js             | inlineflag | -e                  | true  | false
M-proof  | GENERIC_INLINE_PROGRAM_FLAG_RE | hooks/block-clearance-token-write/interpreter-scan.js          | proof   | -e node                 | true  | false
M-mention | MARKER_MENTION_RE          | hooks/lib/protected-basenames.js                                | hits    | node -e "require('fs').writeFileSync('/wf/s1@MK@','x')" | true | false
M-assignword | ASSIGN_WORD_RE          | hooks/block-clearance-token-write/nested-bodies.js                | routes  | FOO=1 node <<EOF\nx\nEOF\n | b=1,f=0,o=0 | b=0,f=0,o=0
M-heredoc | HEREDOC_TERMINATED_RE      | hooks/block-clearance-token-write/nested-bodies.js                | routes  | FOO=1 node <<EOF\nx\nEOF\n | b=1,f=0,o=0 | b=0,f=0,o=1
TABLE
    rm -r -f "$work" 2>/dev/null

    # The score itself, so a future edit that silently stops mutating (a renamed
    # constant, a probe that swallows the difference) cannot leave Section M
    # green on vacuous rows. parser-regex-tests.md sets the bar at 80%; every
    # constant listed above is expected to be killed, so the bar here is 100%.
    assert_eq "M mutation score: every listed constant changes its row's value" "$total/$total" "$killed/$total"
}
