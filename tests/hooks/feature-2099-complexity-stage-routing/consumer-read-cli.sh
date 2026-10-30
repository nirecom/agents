#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumer-read-cli.sh
# Tests: tests/hooks/feature-2099-complexity-stage-routing/_lib.sh
# Tags: complexity, routing, consumers, helpers, scope:issue-specific
# Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints before the consumer
# suites, whose cases call these. No cases of its own: split out of
# consumer-orchestration-cases.sh at the 500-line HARD limit (Pattern A).
# Single-path # Tests: (the sourcing runner) — the calling cases own the targets.
D2099_READ_CLI_LOADED=1

# Every consumer row: skill dir | stage key | level step | Agent-launch step.
# live-e2e-cases.sh walks this table too.
D2099_CONSUMERS="make-detail-plan|detail|MDP-3|MDP-4
write-tests|write_tests|WT-6|WT-7
write-code|write_code|WCD-3|WCD-4"

# What the skill's OWN read command answers, normalized to `level=<v>` then
# `signals=<csv>` (or NONE / a named token). Shared by the signal-forwarding and
# fallback-forwarding suites, which follow this file in separate entrypoints.
d2099sf_read() {
    local f="$1" sid="$2" out first second
    out=$(d2099_consumer_read "$f" "$sid")
    first=$(printf '%s\n' "$out" | sed -n 1p)
    [ "$first" = "__NO_COMMAND__" ] && { echo "NO_READ_COMMAND_IN_SKILL"; return; }
    [ "$first" = "NONE" ] && { echo "NONE"; return; }
    second=$(printf '%s\n' "$out" | sed -n 2p)
    case "$first" in level=*) ;; *) echo "UNPARSEABLE_LEVEL:$first"; return ;; esac
    case "$second" in
        signals=*) printf '%s %s' "$first" "$second" ;;
        '') echo "$first NO_SIGNALS_LINE" ;;
        *) printf '%s UNPARSEABLE_SIGNALS:%s' "$first" "$second" ;;
    esac
}

# The consumer skill's SKILL.md in the checkout under test.
d2099_skill_file() { echo "$SCRIPT_CHECKOUT_ROOT/skills/$1/SKILL.md"; }

# --- which CLI each consumer reads its stored evaluation THROUGH --------------
# #2102 replaced write-tests'/write-code's direct `read-complexity-evaluation
# --stage <s>` call with ONE bundled read at WT-0 / WCD-0: `read-session-facts
# --session "$SESSION_ID"`, whose record carries `COMPLEXITY_LEVEL_<stage>=` and
# `COMPLEXITY_SIGNALS=` — the same two values, other spelling. make-detail-plan
# still calls the direct reader, so CLI, line shape and owning section are all
# per-consumer now. #2460: write-code no longer consumes a stored level at all
# (WCD-3 always runs the shared judge procedure), so only make-detail-plan and
# write-tests are stored-read consumers; the write-code row stays for callers
# that still walk every consumer.
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

# That consumer's stage key, read out of D2099_CONSUMERS (defined by the
# orchestration suite, sourced after this file — the lookup runs at call time)
# rather than re-tabled here.
d2099_consumer_stage() {
    printf '%s\n' "$D2099_CONSUMERS" | grep -m1 -- "^$1|" | cut -d'|' -f2
}

# make-detail-plan's read is documented as `bash -c '<cmd>'` (inner command double-quoted
# only); bounded to the step's own section (d2099_section_cli_line).
d2099_extract_bashc_cmd() {
    local f="$1" cli="$2" line
    line=$(d2099_section_cli_line "$f" "$cli" | grep -oE "bash -c '[^']*'" | head -1)
    [ -n "$line" ] || { echo ""; return; }
    printf '%s' "$line" | sed -E "s/^bash -c '//; s/'$//"
}

# Run a read command exactly as documented, with only the env the skill assumes.
d2099_run_read_cmd() {
    [ -n "$1" ] || { echo "__NO_COMMAND__"; return; }
    SESSION_ID="$2" run_with_timeout bash -c "$1" 2>/dev/null
}

# read-session-facts is documented as a bare backticked command (nothing is spliced
# into it, so it needs no `bash -c` wrapper) — same bound: the step's own section.
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
        *) d2099_extract_bashc_cmd "$f" "$cli" ;;
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
    out=$(d2099_run_read_cmd "$cmd" "$sid")
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
    mdl=$(printf '%s\n' "$out" | grep -m1 -- "^COMPLEXITY_MODEL_$stage=")
    [ -n "$mdl" ] || return 0
    printf 'model=%s\n' "${mdl#COMPLEXITY_MODEL_$stage=}"
}
