#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumer-read-cli.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/read-complexity-evaluation, bin/workflow/read-session-facts
# Tags: complexity, routing, consumers, helpers, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh before the consumer
# suites, whose cases call these. No cases of its own: split out of
# consumer-orchestration-cases.sh at the 500-line HARD limit (Pattern A).
D2099_READ_CLI_LOADED=1

# --- which CLI each consumer reads its stored evaluation THROUGH --------------
# #2102 replaced write-tests'/write-code's direct `read-complexity-evaluation
# --stage <s>` call with ONE bundled read at WT-0 / WCD-0: `read-session-facts
# --session "$SESSION_ID"`, whose record carries `COMPLEXITY_LEVEL_<stage>=` and
# `COMPLEXITY_SIGNALS=` — the same two values, other spelling. make-detail-plan
# still calls the direct reader, so CLI, line shape and owning section are all
# per-consumer now.
d2099_read_cli() {
    case "$1" in
        write-tests|write-code) echo "read-session-facts" ;;
        *) echo "read-complexity-evaluation" ;;
    esac
}

# The step owning that read — the label CO-0/CO-1 report. The binding itself lives
# in the parent runner's d2099_section_step registry.
d2099_read_step() {
    case "$1" in
        write-tests) echo "WT-0" ;;
        write-code)  echo "WCD-0" ;;
        *)           echo "MDP-3" ;;
    esac
}

# The section stating that consumer's level→model mapping. For make-detail-plan it
# is the read step itself; for the other two the read moved to WT-0 / WCD-0 while
# the mapping stayed with the level step (WT-5 / WCD-3 — the derive CLI's section).
d2099_model_map_cli() {
    case "$1" in
        write-tests|write-code) echo "derive-complexity-level" ;;
        *) echo "read-complexity-evaluation" ;;
    esac
}

# That consumer's stage key, read out of D2099_CONSUMERS (defined by the
# orchestration suite, sourced after this file — the lookup runs at call time)
# rather than re-tabled here.
d2099_consumer_stage() {
    printf '%s\n' "$D2099_CONSUMERS" | grep -m1 -- "^$1|" | cut -d'|' -f2
}

# read-session-facts is documented as a bare backticked command (nothing is spliced
# into it, so it needs no `bash -c` wrapper) — different delimiters from
# d2099_extract_cmd's, same bound: the step's own section.
d2099_extract_backtick_cmd() {
    local f="$1" cli="$2" line
    line=$(d2099_section_cli_line "$f" "$cli" | grep -oE '`[^`]*'"$cli"'[^`]*`' | head -1)
    [ -n "$line" ] || { echo ""; return; }
    printf '%s' "$line" | sed -E 's/^`//; s/`$//'
}

# The read command THIS consumer documents, whichever CLI that is.
d2099_extract_read_cmd() {
    local f="$1" cli
    cli=$(d2099_read_cli "$(d2099_skill_dir_name "$f")")
    case "$cli" in
        read-session-facts) d2099_extract_backtick_cmd "$f" "$cli" ;;
        *) d2099_extract_cmd "$f" "$cli" ;;
    esac
}

# Run that command and normalize the answer to `level=<v>` + `signals=<csv|none>`,
# or the bare `NONE` sentinel — exactly what the direct reader emits, so every
# existing case keeps parsing what it always parsed. For read-session-facts the
# two values are SELECTED BY KEY out of the fixed record: never re-derived from
# the other keys, never defaulted, and a missing key is a named token rather than
# a silent empty read.
d2099_consumer_read() {
    local f="$1" sid="$2" skill stage cmd out lvl sig
    skill=$(d2099_skill_dir_name "$f")
    cmd=$(d2099_extract_read_cmd "$f")
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    out=$(d2099_run_skill_cmd "$cmd" "$sid")
    if [ "$(d2099_read_cli "$skill")" = "read-complexity-evaluation" ]; then
        printf '%s\n' "$out"
        return
    fi
    stage=$(d2099_consumer_stage "$skill")
    lvl=$(printf '%s\n' "$out" | grep -m1 -- "^COMPLEXITY_LEVEL_$stage=")
    [ -n "$lvl" ] || { echo "MISSING_KEY:COMPLEXITY_LEVEL_$stage"; return; }
    lvl="${lvl#COMPLEXITY_LEVEL_$stage=}"
    [ "$lvl" = "NONE" ] && { echo "NONE"; return; }
    printf 'level=%s\n' "$lvl"
    sig=$(printf '%s\n' "$out" | grep -m1 -- '^COMPLEXITY_SIGNALS=')
    # No second line when the key is absent, so the signal-forwarding suite's own
    # NO_SIGNALS_LINE branch stays reachable.
    [ -n "$sig" ] || return 0
    printf 'signals=%s\n' "${sig#COMPLEXITY_SIGNALS=}"
}
