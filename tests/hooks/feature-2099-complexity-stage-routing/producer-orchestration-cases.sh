#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/producer-orchestration-cases.sh
# Tests: skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, skills/_shared/complexity-and-outline-skip.md, bin/workflow/normalize-judge-signals, bin/workflow/record-complexity-and-skip, bin/workflow/read-complexity-evaluation
# Tags: complexity, routing, producers, integration, skip-dispatch, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# CI-C1b and A3a are the two WRITE points (detail.md P4). Both delegate to the shared
# COS procedure (skills/_shared/complexity-and-outline-skip.md), so the COS-2 normalize
# line and the COS-3 record line are extracted from THAT doc and EXECUTED; the raw
# event, the per-stage levels and the skip dispatch are asserted on the result.

# skill dir | step label | write target
D2099P_PRODUCERS="clarify-intent|CI-C1b|outline
workflow-init|A3a|outline"

D2099P_COS_REF="skills/_shared/complexity-and-outline-skip.md"

d2099p_skill_file() { echo "$SCRIPT_CHECKOUT_ROOT/skills/$1/SKILL.md"; }
d2099p_cos_file() { echo "$SCRIPT_CHECKOUT_ROOT/$D2099P_COS_REF"; }

# The backticked command of the shared doc that runs <cli> (COS-2 normalize, COS-3 record).
d2099p_cos_cmd() {
    grep -oE "(node|bash) \"\\\$AGENTS_MAIN_ROOT/bin/workflow/$1\"[^\`]*" "$(d2099p_cos_file)" | head -1
}

D2099P_PLANS=""
d2099p_plans_dir() {
    if [ -z "$D2099P_PLANS" ]; then
        D2099P_PLANS="$TMPDIR_BASE/producer-plans"
        mkdir -p "$D2099P_PLANS"
    fi
    printf '%s' "$D2099P_PLANS"
}

# COS-2 line with its <PLANS_DIR>/<SESSION_ID> slots filled; prints its stdout (<SIGNALS_FILE>).
d2099p_cos2_run() {
    local sid="$1" cmd
    cmd=$(d2099p_cos_cmd normalize-judge-signals)
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    cmd=${cmd//<PLANS_DIR>/$(d2099p_plans_dir)}
    cmd=${cmd//<SESSION_ID>/$sid}
    mkdir -p "$TMPDIR_BASE/producer-cwd"
    (cd "$TMPDIR_BASE/producer-cwd" && run_with_timeout bash -c "$cmd" 2>/dev/null)
}

# COS-3 line with its slots filled; prints the bare SKIP_DISPATCH value (prefix stripped).
d2099p_cos3_run() {
    local sid="$1" sigfile="$2" c1="${3:-true}" c2="${4:-true}" cmd out
    cmd=$(d2099p_cos_cmd record-complexity-and-skip)
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    cmd=${cmd//<SESSION_ID>/$sid}
    cmd=${cmd//<SIGNALS_FILE>/$sigfile}
    cmd=$(printf '%s' "$cmd" | sed -E -e "s/--so-c1 <[^>]*>/--so-c1 $c1/" -e "s/--so-c2 <[^>]*>/--so-c2 $c2/")
    mkdir -p "$TMPDIR_BASE/producer-cwd"
    out=$(cd "$TMPDIR_BASE/producer-cwd" && run_with_timeout bash -c "$cmd" 2>/dev/null | tail -1)
    printf '%s' "${out#SKIP_DISPATCH=}"
}

# The whole COS chain from the judge's raw text: Write raw file (COS-1) -> COS-2 -> COS-3.
d2099p_run_raw() {
    local f="$1" sid="$2" raw="$3" c1="${4:-true}" c2="${5:-true}" sigfile
    grep -qF -- "$D2099P_COS_REF" "$f" 2>/dev/null || { echo "__NO_COMMAND__"; return; }
    printf '%s\n' "$raw" > "$(d2099p_plans_dir)/$sid-complexity-judge-raw.txt"
    sigfile=$(d2099p_cos2_run "$sid")
    [ -n "$sigfile" ] || { echo "__NO_COMMAND__"; return; }
    [ "$sigfile" = "__NO_COMMAND__" ] && { echo "__NO_COMMAND__"; return; }
    d2099p_cos3_run "$sid" "$sigfile" "$c1" "$c2"
}

# Raw-CSV contract (live-e2e-cases.sh depends on it): the judge's id list becomes a
# `SIGNALS:` line; an empty csv is the judge's zero-signal marker `none`.
d2099p_run_producer() {
    local f="$1" sid="$2" signals="$3" c1="${4:-true}" c2="${5:-true}"
    d2099p_run_raw "$f" "$sid" "SIGNALS: ${signals:-none}" "$c1" "$c2"
}

# The DISPATCH BRANCH itself (COS-4): a comparison of the value against the bare tokens.
d2099p_run_dispatch_branch() {
    local val
    val=$(d2099p_run_producer "$@")
    case "$val" in
        no-skip | advanced | need-judgment) printf 'branch:%s' "$val" ;;
        __NO_COMMAND__) printf '%s' "$val" ;;
        *) printf 'branch:NO_MATCH[%s]' "$val" ;;
    esac
}

# The raw persisted event, straight out of the append-only log — never through the
# compatibility read that backfills `levels` (detail.md D6).
d2099p_raw_event() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
if (!ev.length) { console.log("__NO_EVENT__"); process.exit(0); }
const e = ev[ev.length - 1];
console.log("n=" + ev.length
  + " level=" + String(e.level)
  + " signals=" + JSON.stringify(e.signals)
  + " levels=" + (e.levels ? [e.levels.detail, e.levels.write_tests, e.levels.write_code].join("/") : String(e.levels)));
' 2>&1
}

# Whether the wrapper settled an outline skip judgment for this session.
d2099p_skip_record() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const sj = s && s.skip_judgment && s.skip_judgment.outline;
console.log(sj ? "present:" + String(sj.all_conditions_met) : "absent");
' 2>/dev/null
}

# The three stage levels as the CONSUMERS would read them back.
d2099p_stage_levels() {
    local sid="$1" st out acc=""
    for st in detail write_tests write_code; do
        out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | head -1)
        acc="$acc${acc:+/}${out#level=}"
    done
    printf '%s' "$acc"
}

# PO-1: the extraction must have teeth. Every assertion below measures an empty
# string if the shared doc carries no runnable line, so the lines are pinned first.
d2099p_commands_are_real() {
    local name step target f sec cos rec nrm
    cos=$(d2099p_cos_file)
    rec=$(d2099p_cos_cmd record-complexity-and-skip)
    nrm=$(d2099p_cos_cmd normalize-judge-signals)
    if [ -z "$rec" ] || [ -z "$nrm" ]; then
        fail "PO-1 the shared COS procedure carries no extractable COS-2 normalize / COS-3 record command line"
        return
    fi
    pass "PO-1 the shared COS procedure carries extractable COS-2 and COS-3 command lines"
    assert_contains "PO-1a COS-3 passes the session through" '--session "<SESSION_ID>"' "$rec"
    # PO-1b: the #2099 PO-INJ contract in static form — csv by FILE, no splice slot.
    assert_contains "PO-1b COS-3 passes the judged csv by the normalized file" \
        '--signals-file "<SIGNALS_FILE>"' "$rec"
    assert_not_contains "PO-1b1 COS-3 carries no literal --signals <csv> splice slot (PO-INJ)" "--signals <" "$rec"
    assert_not_contains "PO-1c COS-3 no longer passes --verdict" "--verdict" "$rec"
    assert_contains "PO-1e COS-3 settles the skip in the same call and prints only the dispatch line (--dispatch-only)" \
        "--dispatch-only" "$rec"
    assert_not_contains "PO-1g COS-3 needs no pipe or capture (no '| tail')" "| tail" "$rec"
    assert_contains "PO-1h COS-2 normalizes with --stage complexity" "--stage complexity" "$nrm"

    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        sec=$(d2099_skill_section "$f" "$step")
        assert_contains "PO-1i $step delegates to the shared COS procedure" "$D2099P_COS_REF" "$sec"
        assert_contains "PO-1d COS-3 names the skip target $step relies on" "--target $target" "$rec"
    done <<EOF
$D2099P_PRODUCERS
EOF

    # CPR-ORTH: the two write points are symmetric, so both must reference the SAME doc.
    local a b
    a=$(d2099_skill_section "$(d2099p_skill_file clarify-intent)" CI-C1b | grep -cF -- "$D2099P_COS_REF")
    b=$(d2099_skill_section "$(d2099p_skill_file workflow-init)" A3a | grep -cF -- "$D2099P_COS_REF")
    assert_eq "PO-2 CI-C1b and A3a each reference the one shared COS procedure (CPR-ORTH)" "1 1" "$a $b"
    [ -f "$cos" ] || fail "PO-2a the shared COS procedure file exists"
}

# PO-3..: run the COS chain for the three signal shapes the judge can produce — zero
# signals, several signals, and the undecidable token — and assert what was PERSISTED,
# what the stages DERIVE, and how the skip dispatched.
d2099p_producer_scenarios() {
    local name step target f label sid signals want_dispatch want_levels want_raw want_skip
    # scenario | signals | dispatch | detail/write_tests/write_code | raw signals | skip record
    local SCENARIOS='empty||advanced|low/low/low|[]|present:true
multi|S2-architecture,S6-long-plan|need-judgment|high/high/high|["S2-architecture","S6-long-plan"]|absent
undecidable|S0-undecidable|need-judgment|high/high/high|["UNRECOGNIZED(1)"]|absent'
    # Spec: complexity-routing.js canonicalizeSignalsForPersistence (#2148) persists a
    # non-SIGNAL_IDS token (S0-undecidable included) as UNRECOGNIZED(n); the level stays high.

    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        while IFS='|' read -r label signals want_dispatch want_levels want_raw want_skip; do
            [ -n "$label" ] || continue
            sid=$(new_session "prod-$name-$label")
            assert_eq "PO-3 $step [$label] the COS-3 call prints SKIP_DISPATCH=$want_dispatch" \
                "$want_dispatch" "$(d2099p_run_producer "$f" "$sid" "$signals")"
            assert_eq "PO-3a $step [$label] ... so the COS-4 branch on the bare token takes the '$want_dispatch' arm" \
                "branch:$want_dispatch" \
                "$(d2099p_run_dispatch_branch "$f" "$(new_session "prodbr-$name-$label")" "$signals")"
            assert_eq "PO-4 $step [$label] exactly one raw complexity_evaluation event carries the recorded shape" \
                "n=1 level=$( [ -z "$signals" ] && echo low || echo high ) signals=$want_raw levels=$want_levels" \
                "$(d2099p_raw_event "$sid")"
            assert_eq "PO-5 $step [$label] the three stages read back the D2 routing levels" \
                "$want_levels" "$(d2099p_stage_levels "$sid")"
            assert_eq "PO-6 $step [$label] the outline skip judgment is settled as documented" \
                "$want_skip" "$(d2099p_skip_record "$sid")"
        done <<SCEN
$SCENARIOS
SCEN
    done <<EOF
$D2099P_PRODUCERS
EOF
}

# --- PO-8: the zero-signal marker at the WRITE point ---------------------------
# CI-C1b/A3a receive `SIGNALS: none` from the judge. COS-2 (normalize) owns the
# translation to the empty csv; a bare `none` WITHOUT the SIGNALS line is not the
# marker and must route undecidable-high, which keeps the normalize step load-bearing.
d2099p_zero_signal_marker() {
    local name step target f sid
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")

        sid=$(new_session "prodnone-$name")
        assert_eq "PO-8a $step: a 'SIGNALS: none' judgment leaves SKIP_DISPATCH holding 'advanced'" \
            "advanced" "$(d2099p_run_raw "$f" "$sid" "SIGNALS: none")"
        assert_eq "PO-8b $step: ... persisting the zero-signal evaluation, not an undecidable one" \
            "n=1 level=low signals=[] levels=low/low/low" "$(d2099p_raw_event "$sid")"
        assert_eq "PO-8c $step: ... and the three stages read back low" \
            "low/low/low" "$(d2099p_stage_levels "$sid")"

        sid=$(new_session "prodnonelit-$name")
        d2099p_run_raw "$f" "$sid" "none" >/dev/null
        assert_eq "PO-8d $step: a bare 'none' with no SIGNALS line is S0-undecidable and routes high (normalize-judge-signals)" \
            "n=1 level=high signals=[\"UNRECOGNIZED(1)\"] levels=high/high/high" "$(d2099p_raw_event "$sid")"
        assert_eq "PO-8e $step: ... so no outline skip is auto-advanced off a marker nobody emitted" \
            "absent" "$(d2099p_skip_record "$sid")"
    done <<EOF
$D2099P_PRODUCERS
EOF
}

# PO-7: the so_c1/so_c2 override. An explicitly false condition outranks the
# zero-signal auto branch — without this row, "advanced" on the empty scenario
# above could equally be produced by a wrapper that ignores so_c1/so_c2 entirely.
d2099p_so_condition_override() {
    local name step target f sid
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        sid=$(new_session "prod-$name-soc1")
        assert_eq "PO-7 $step: --so-c1 false prints a bare no-skip even on a zero-signal evaluation" \
            "no-skip" "$(d2099p_run_producer "$f" "$sid" "" false true)"
        assert_eq "PO-7c $step: ... and the COS-4 branch takes the no-skip arm" \
            "branch:no-skip" \
            "$(d2099p_run_dispatch_branch "$f" "$(new_session "prodbr-$name-soc1")" "" false true)"
        assert_eq "PO-7a $step: ... and no outline skip judgment is written" \
            "absent" "$(d2099p_skip_record "$sid")"
        assert_eq "PO-7b $step: ... while the complexity evaluation is still recorded" \
            "n=1 level=low signals=[] levels=low/low/low" "$(d2099p_raw_event "$sid")"
    done <<EOF
$D2099P_PRODUCERS
EOF
}

# PO-INJ-4/5: exactly one of --signals / --signals-file. Both flags or neither is
# a documented CLI error at BOTH layers — the bash wrapper (exit 2) and the node
# CLI (exit 1) — so no caller can end up with an ambiguous or absent csv source.
d2099p_signals_flag_arity() {
    local sid f out rc
    f="$(d2099p_plans_dir)/arity-signals.txt"
    printf 'S1-multi-file\n' > "$f"

    sid=$(new_session "prodarity-both-w")
    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" \
        --session "$sid" --signals "S1-multi-file" --signals-file "$f" --target outline 2>&1) || rc=$?
    assert_eq "PO-INJ-4 the wrapper rejects --signals and --signals-file together (exit 2)" "2" "$rc"
    assert_contains "PO-INJ-4a ... with the documented mutual-exclusion message" \
        "mutually exclusive" "$out"
    assert_eq "PO-INJ-4b ... and persists nothing" "__NO_EVENT__" "$(d2099p_raw_event "$sid")"

    sid=$(new_session "prodarity-both-n")
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S1-multi-file" \
        --signals-file "$f" 2>&1) || rc=$?
    assert_eq "PO-INJ-4c the node CLI rejects both flags too (exit 1)" "1" "$rc"
    assert_contains "PO-INJ-4d ... with the same mutual-exclusion message" "mutually exclusive" "$out"

    sid=$(new_session "prodarity-none-w")
    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" \
        --session "$sid" --target outline 2>&1) || rc=$?
    assert_eq "PO-INJ-5 the wrapper rejects neither flag being passed (exit 2)" "2" "$rc"
    assert_contains "PO-INJ-5a ... with the documented required-flag message" \
        "is required" "$out"
    assert_eq "PO-INJ-5b ... and persists nothing" "__NO_EVENT__" "$(d2099p_raw_event "$sid")"

    sid=$(new_session "prodarity-none-n")
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" 2>&1) || rc=$?
    assert_eq "PO-INJ-5c the node CLI rejects neither flag too (exit 1)" "1" "$rc"
    assert_contains "PO-INJ-5d ... with the same required-flag message" "is required" "$out"
}

# PO-INJ-6: the benign half of the redesign. A legitimate csv delivered by file
# must record EXACTLY what the same csv delivered by --signals records — otherwise
# the injection-safe path would be a second, divergent parser.
d2099p_signals_file_round_trip() {
    local label csv sid_f sid_s f
    while IFS='|' read -r label csv; do
        [ -n "$label" ] || continue
        csv=${csv//%EMPTY%/}
        sid_f=$(new_session "prodrt-file-$label")
        f="$(d2099p_plans_dir)/$sid_f-roundtrip.txt"
        printf '%s\n' "$csv" > "$f"
        run_with_timeout node "$BIN_RECORD" --session "$sid_f" --signals-file "$f" >/dev/null 2>&1
        sid_s=$(new_session "prodrt-arg-$label")
        run_with_timeout node "$BIN_RECORD" --session "$sid_s" --signals "$csv" >/dev/null 2>&1
        assert_eq "PO-INJ-6 [$label] --signals-file records what --signals records" \
            "$(d2099p_raw_event "$sid_s")" "$(d2099p_raw_event "$sid_f")"
    done <<RT
empty|%EMPTY%
single|S1-multi-file
multi|S2-architecture,S6-long-plan
spaced|S2-architecture, S6-long-plan
undecidable|S0-undecidable
RT
}

d2099p_commands_are_real
d2099p_producer_scenarios
d2099p_zero_signal_marker
d2099p_so_condition_override
d2099p_signals_flag_arity
d2099p_signals_file_round_trip
