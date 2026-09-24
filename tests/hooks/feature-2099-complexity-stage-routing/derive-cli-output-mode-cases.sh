#!/bin/bash
# tests/feature-2099-complexity-stage-routing/derive-cli-output-mode-cases.sh
# Tests: bin/workflow/derive-complexity-level, hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, cli, output-mode, arg-parsing, table-driven, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# Why: derive-complexity-level has THREE output modes whose selection is decided
# by the ORDER of the checks in main(), not by any rejection of conflicting
# flags. No sibling suite ever passes two modes at once, so that precedence is
# unpinned and a reordered main() would silently change what every `--print-*`
# caller receives. Cases below fix the contract in both directions.

# One invocation: "<rc> <first-line>", stderr folded in so a usage error shows.
d2099dm_run() {
    local rc=0 out
    out=$(run_with_timeout node "$BIN_DERIVE" "$@" 2>&1) || rc=$?
    printf '%s %s' "$rc" "$(printf '%s\n' "$out" | head -1)"
}

d2099dm_rc() { d2099dm_run "$@" | cut -d' ' -f1; }

# Whole stdout, stderr discarded — for comparing two spellings byte-for-byte.
d2099dm_stdout() {
    run_with_timeout node "$BIN_DERIVE" "$@" 2>/dev/null
}

# DM-1: each print mode ALONE — the baseline every combination below compares
# against. Without it, "the combination printed the table" could equally mean
# "every invocation prints the table".
d2099dm_single_modes() {
    local table ids
    table=$(d2099dm_stdout --print-markdown-table)
    ids=$(d2099dm_stdout --print-signal-ids)

    assert_contains "DM-1 --print-markdown-table renders the per-stage routing table" \
        '| `write_code` |' "$table"
    assert_contains "DM-2 --print-signal-ids renders the signal id list" \
        '- `S1-multi-file`' "$ids"
    # The two modes must be DISTINGUISHABLE or no precedence case below has teeth.
    if [ "$table" = "$ids" ]; then
        fail "DM-3 both print modes emit identical output — no case below could tell which branch ran"
    else
        pass "DM-3 the two print modes emit different output, so the precedence cases can tell them apart"
    fi
    assert_eq "DM-4 --print-markdown-table exits 0 with no stage and no signals" \
        "0" "$(d2099dm_rc --print-markdown-table)"
    assert_eq "DM-5 --print-signal-ids exits 0 with no stage and no signals" \
        "0" "$(d2099dm_rc --print-signal-ids)"
}

# DM-6: BOTH print flags together, in both orders. The implemented contract is
# fixed precedence — the table is checked first — not argv order and not a
# rejection. Pinning both orders is what makes it deterministic rather than an
# accident of how the caller happened to type it.
d2099dm_both_print_flags() {
    local table forward reverse doubled
    table=$(d2099dm_stdout --print-markdown-table)
    forward=$(d2099dm_stdout --print-markdown-table --print-signal-ids)
    reverse=$(d2099dm_stdout --print-signal-ids --print-markdown-table)
    doubled=$(d2099dm_stdout --print-markdown-table --print-markdown-table)

    assert_eq "DM-6 both print flags together yield the markdown table" "$table" "$forward"
    assert_eq "DM-7 ... and reversing the argv order does not change the answer" "$table" "$reverse"
    assert_eq "DM-8 repeating one print flag is idempotent, not a double render" "$table" "$doubled"
    assert_eq "DM-9 both print flags together still exit 0" \
        "0" "$(d2099dm_rc --print-markdown-table --print-signal-ids)"
}

# DM-10: a print flag alongside derivation arguments. The print branch runs
# BEFORE stage validation and before the --signals arity checks, so the CLI must
# answer the requested table and never a level — a caller handed `level=` here
# would act on a stage it never asked to be judged on.
d2099dm_print_beats_derivation() {
    local table ids got f
    table=$(d2099dm_stdout --print-markdown-table)
    ids=$(d2099dm_stdout --print-signal-ids)
    f="$WORKFLOW_PLANS_DIR/dm-signals.txt"
    printf 'S1-multi-file' > "$f"

    assert_eq "DM-10 --print-markdown-table beside a full derivation call prints the table, not a level" \
        "$table" "$(d2099dm_stdout --stage detail --signals "S1-multi-file" --print-markdown-table)"
    assert_eq "DM-11 --print-signal-ids beside a full derivation call prints the id list, not a level" \
        "$ids" "$(d2099dm_stdout --print-signal-ids --stage write_code --signals "")"

    got=$(d2099dm_stdout --print-markdown-table --stage detail --signals "S1-multi-file")
    assert_not_contains "DM-12 ... and no level= line leaks into the printed table" "level=" "$got"

    # Each of these WOULD be a usage error on the derivation path; the print
    # branch precedes all three checks, so each must still exit 0 and print.
    assert_eq "DM-13 an invalid --stage beside --print-markdown-table is never reached (exit 0)" \
        "0" "$(d2099dm_rc --print-markdown-table --stage nonsense --signals "")"
    assert_eq "DM-14 a missing --signals beside --print-signal-ids is never reached (exit 0)" \
        "0" "$(d2099dm_rc --print-signal-ids --stage detail)"
    assert_eq "DM-15 the --signals/--signals-file exclusion is never reached either (exit 0)" \
        "0" "$(d2099dm_rc --print-markdown-table --stage detail --signals "S1-multi-file" --signals-file "$f")"
    assert_contains "DM-15b ... and the unreadable path in DM-15 was genuinely never opened" \
        '| `write_code` |' "$(d2099dm_stdout --print-markdown-table --stage detail --signals-file "$WORKFLOW_PLANS_DIR/dm-absent.txt")"
}

# DM-16: the teeth for DM-13..DM-15 — the SAME invocations WITHOUT the print flag
# are rejected. Otherwise those would pass equally on a CLI that validates nothing.
d2099dm_derivation_path_still_validates() {
    local f got
    f="$WORKFLOW_PLANS_DIR/dm-signals.txt"
    printf 'S1-multi-file' > "$f"

    assert_eq "DM-16 without a print flag, an invalid --stage is a usage error (exit 1)" \
        "1" "$(d2099dm_rc --stage nonsense --signals "")"
    assert_eq "DM-17 without a print flag, a missing --signals is a usage error (exit 1)" \
        "1" "$(d2099dm_rc --stage detail)"
    assert_eq "DM-18 without a print flag, both signal sources together is a usage error (exit 1)" \
        "1" "$(d2099dm_rc --stage detail --signals "S1-multi-file" --signals-file "$f")"
    assert_eq "DM-19 without a print flag, no arguments at all is a usage error (exit 1)" \
        "1" "$(d2099dm_rc)"

    # And the derivation path itself still answers, so DM-16..DM-19 are not
    # measuring a CLI that has started rejecting everything.
    got=$(d2099dm_run --stage write_code --signals "S1-multi-file")
    assert_eq "DM-20 the plain derivation invocation still answers its own stage's level" \
        "0 level=high" "$got"
}

# DM-21: an unknown argument beside a print flag. Unknown tokens are rejected by
# the same parse loop that SETS the print flags, so the rejection happens before
# the print branch and must stay a usage error rather than being swallowed by
# the mode that was also requested.
d2099dm_unknown_argument() {
    assert_eq "DM-21 an unknown flag beside --print-markdown-table is still rejected (exit 1)" \
        "1" "$(d2099dm_rc --print-markdown-table --bogus)"
    assert_contains "DM-22 ... and the rejection names the unknown argument" \
        "unknown argument: --bogus" "$(run_with_timeout node "$BIN_DERIVE" --print-markdown-table --bogus 2>&1 || true)"
    assert_eq "DM-23 ... and the rejected call emits nothing on stdout" \
        "" "$(d2099dm_stdout --print-markdown-table --bogus || true)"
}

# DM-24: the print modes are PURE — identical bytes per run, no session state
# read. A table that varied per invocation could not be pasted into a skill
# prompt, which is the only reason these modes exist.
d2099dm_print_is_deterministic() {
    local a b
    a=$(d2099dm_stdout --print-markdown-table)
    b=$(d2099dm_stdout --print-markdown-table)
    assert_eq "DM-24 --print-markdown-table renders identically on a repeat run" "$a" "$b"
    a=$(d2099dm_stdout --print-signal-ids)
    b=$(d2099dm_stdout --print-signal-ids)
    assert_eq "DM-25 --print-signal-ids renders identically on a repeat run" "$a" "$b"
}

d2099dm_single_modes
d2099dm_both_print_flags
d2099dm_print_beats_derivation
d2099dm_derivation_path_still_validates
d2099dm_unknown_argument
d2099dm_print_is_deterministic
