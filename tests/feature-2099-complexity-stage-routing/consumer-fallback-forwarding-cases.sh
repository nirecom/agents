#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumer-fallback-forwarding-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/derive-complexity-level, hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, consumers, signals, fallback, signals-file, scope:issue-specific
# Sourced after the consumer orchestration + signal-forwarding suites — the
# d2099_* command extraction and the signals-file runner come from there.

# Why: consumer-signal-forwarding-cases.sh forwards signals on the STORED path,
# where the reader hands back a `signals=` line. On the NONE fallback the list
# never enters a reader at all: the orchestrator Writes it to a per-stage file
# and derive-complexity-level reads it back. That leg was pinned only by its
# level, so a csv reaching the wrong stage's file was invisible.

D2099FF_CONSUMERS="make-detail-plan|detail
write-tests|write_tests
write-code|write_code"

# The judged csv, run through ONE consumer's own documented fallback command.
# Answers "<level=v>" or a named token — never a bare empty string, which would
# read as a passing comparison against another empty string.
d2099ff_derive() {
    local f="$1" sid="$2" csv="$3" out first
    out=$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "derive-complexity-level")" "$sid" "$csv")
    first=$(printf '%s\n' "$out" | sed -n 1p)
    case "$first" in
        level=*) printf '%s' "$first" ;;
        '') printf 'NO_OUTPUT' ;;
        *) printf 'UNPARSEABLE:%s' "$first" ;;
    esac
}

# The FILE that command opens, taken out of the command itself (CPR-SSOT with
# the runner), so a renamed path in a SKILL.md moves the assertion with it.
d2099ff_path() {
    local f="$1" sid="$2" cmd
    cmd=$(d2099_extract_cmd "$f" "derive-complexity-level")
    [ -n "$cmd" ] || { printf 'NO_DERIVE_COMMAND_IN_SKILL'; return; }
    d2099_signals_file_path "$(d2099_fill_signals_file_cmd "$cmd" "$sid")"
}

# CFF-1/CFF-2: the fallback is only reachable when the reader says NONE, and the
# reader's `signals=` line — the one CSF-1..CSF-8 forward — does not exist there.
# Without this gate every row below could be exercising the stored path instead.
d2099ff_fallback_entry_gate() {
    local sid name stage f
    sid=$(new_session ffnone)   # created, never recorded into
    while IFS='|' read -r name stage; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        assert_eq "CFF-1 $name: an unrecorded session reads NONE, which is what routes it to the signals-file fallback" \
            "NONE" "$(d2099sf_read "$f" "$sid")"
        assert_not_contains "CFF-2 $name: the fallback's own command answers with a level only — no signals= line comes back out of it" \
            "signals=" "$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "derive-complexity-level")" "$sid" "S3-security")"
    done <<EOF
$D2099FF_CONSUMERS
EOF
}

# CFF-3: each consumer writes to its OWN file. A shared path would let whichever
# stage judged last decide every stage's model, and the levels below would agree
# by accident rather than by routing.
d2099ff_paths_are_stage_distinct() {
    local sid name stage f p out="" seen
    sid=$(new_session ffpath)
    while IFS='|' read -r name stage; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        p=$(d2099ff_path "$f" "$sid")
        out="$out$name -> $(basename "$p")"$'\n'
    done <<EOF
$D2099FF_CONSUMERS
EOF
    assert_block "CFF-3 each consumer's fallback names its own per-stage signals file under the session id" \
        "$(printf '%s' "$out")" <<EOF
make-detail-plan -> $sid-detail-signals.txt
write-tests -> $sid-write-tests-signals.txt
write-code -> $sid-write-code-signals.txt
EOF
    seen=$(printf '%s' "$out" | grep -c 'signals.txt')
    assert_eq "CFF-4 ... and all three resolved to a real filename rather than an unfilled slot" "3" "$seen"
}

# CFF-5..CFF-9: the payload scenarios. One table per csv shape, all three stages
# in each, so a forwarder that dropped the list (or forwarded a constant) shows
# up as the wrong stage flipping rather than as a uniform failure.
d2099ff_payload_table() {
    local label="$1" csv="$2" sid name stage out=""
    sid=$(new_session "ff$label")
    while IFS='|' read -r name stage; do
        [ -n "$name" ] || continue
        out="$out$name -> $(d2099ff_derive "$(d2099_skill_file "$name")" "$sid" "$csv")"$'\n'
    done <<EOF
$D2099FF_CONSUMERS
EOF
    printf '%s' "$out"
}

d2099ff_zero_signals() {
    assert_block "CFF-5 a zero-signal judgment routes every stage low through the fallback file" \
        "$(d2099ff_payload_table zero "")" <<'EOF'
make-detail-plan -> level=low
write-tests -> level=low
write-code -> level=low
EOF
}

d2099ff_one_signal() {
    # S1-multi-file is the #2099 case itself: low for detail and write_tests,
    # high for write_code off ONE forwarded id.
    assert_block "CFF-6 a one-signal judgment splits write_code off from the other two" \
        "$(d2099ff_payload_table one "S1-multi-file")" <<'EOF'
make-detail-plan -> level=low
write-tests -> level=low
write-code -> level=high
EOF
    # The mirror split, so a forwarder keyed to write_code alone is caught: here
    # detail is the odd stage out (detail has no S3-security row, detail.md D2).
    assert_block "CFF-7 ... and a different one-signal judgment splits detail off instead" \
        "$(d2099ff_payload_table onesec "S3-security")" <<'EOF'
make-detail-plan -> level=low
write-tests -> level=high
write-code -> level=high
EOF
}

d2099ff_multi_signal() {
    # Three ids in one file. Only S3-security escalates, and it must still be
    # seen beside two non-escalating neighbours — a forwarder that read only the
    # first token would answer low/low/high here.
    assert_block "CFF-8 a multi-signal judgment is parsed past its first token" \
        "$(d2099ff_payload_table multi "S1-multi-file,S3-security,S6-long-plan")" <<'EOF'
make-detail-plan -> level=low
write-tests -> level=high
write-code -> level=high
EOF
}

d2099ff_undecidable() {
    # The substitution the three skills mandate when the judgment cannot be
    # parsed. It must fail HIGH on every stage — including detail, which no real
    # signal in this file escalates — or an unparseable judge silently downgrades.
    assert_block "CFF-9 the S0-undecidable substitution fails high on every stage, detail included" \
        "$(d2099ff_payload_table undec "S0-undecidable")" <<'EOF'
make-detail-plan -> level=high
write-tests -> level=high
write-code -> level=high
EOF
}

# CFF-10/CFF-11: the teeth. The rows above would all pass against a CLI that
# ignored the file and answered from the stage alone, so one stage is driven
# with two different csvs and must answer differently; and one stage's file is
# seeded while ANOTHER stage runs, which must not pick it up.
d2099ff_file_content_is_what_decides() {
    local sid f_wt f_de out
    sid=$(new_session ffteeth)
    f_wt=$(d2099_skill_file write-tests)
    out="escalating -> $(d2099ff_derive "$f_wt" "$sid" "S3-security")"$'\n'
    out="${out}empty -> $(d2099ff_derive "$f_wt" "$sid" "")"$'\n'
    assert_block "CFF-10 one stage, one path, two file contents — and the answer changes with the content" \
        "$(printf '%s' "$out")" <<'EOF'
escalating -> level=high
empty -> level=low
EOF

    # Seed detail's file with an escalating id, then run write_tests with none.
    f_de=$(d2099_skill_file make-detail-plan)
    d2099ff_derive "$f_de" "$sid" "S3-security" >/dev/null
    assert_eq "CFF-11 a csv sitting in another stage's signals file never reaches this stage's derivation" \
        "level=low" "$(d2099ff_derive "$f_wt" "$sid" "")"
}

# CFF-12: SOURCE GAP, deliberately not asserted as a contract.
d2099ff_wt6_signals_line_gap() {
    skip "CFF-12 SOURCE GAP: skills/write-tests/SKILL.md WT-6 requires \`task_complexity_signals\`: the \`signals=\` line from WT-5 verbatim, but WT-5's fallback branch runs derive-complexity-level, which emits level= only (CFF-2). On the NONE path the field has no documented producer"
}

d2099ff_fallback_entry_gate
d2099ff_paths_are_stage_distinct
d2099ff_zero_signals
d2099ff_one_signal
d2099ff_multi_signal
d2099ff_undecidable
d2099ff_file_content_is_what_decides
d2099ff_wt6_signals_line_gap
