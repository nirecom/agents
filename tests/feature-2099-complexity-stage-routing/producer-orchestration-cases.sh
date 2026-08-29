#!/bin/bash
# tests/feature-2099-complexity-stage-routing/producer-orchestration-cases.sh
# Tests: skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, bin/workflow/record-complexity-and-skip, bin/workflow/read-complexity-evaluation
# Tags: complexity, routing, producers, integration, skip-dispatch, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# CI-C1b and A3a are the two WRITE points (detail.md P4). consumers-static.sh only
# greps them, so a malformed SIGNALS extraction or an unrunnable wrapper line would
# pass. Here each skill's OWN command line is extracted and EXECUTED, and the raw
# event, the per-stage levels and the skip dispatch are asserted on the result.

# skill dir | step label | write target
D2099P_PRODUCERS="clarify-intent|CI-C1b|outline
workflow-init|A3a|outline"

d2099p_skill_file() { echo "$AGENTS_DIR/skills/$1/SKILL.md"; }

# The write point's own line, bounded to the CI-C1b / A3a section it must live in.
# A whole-file grep would take the first `record-complexity-and-skip` mention
# anywhere — CI-C1c's prose about the wrapper sits three lines below CI-C1b — and
# validate that instead of the required step (round-10 C1). PO-0 below reports a
# missing section, a missing line or a duplicate by name.
d2099p_section_line() {
    d2099_section_cli_line "$1" "record-complexity-and-skip"
}

# Pull the WHOLE assignment the skill tells the orchestrator to run — the
# `SKIP_DISPATCH=$(... | tail -1)` line verbatim, capture and pipeline included.
# Round 4 extracted only the inner command and then stripped a `SKIP_DISPATCH=`
# prefix off the result, which normalized away the very contract CI-C1b/A3a state:
# what `$SKIP_DISPATCH` HOLDS is what CI-C1c/A3b compare against bare tokens.
d2099p_extract_assignment() {
    local f="$1" line
    line=$(d2099p_section_line "$f" | grep -oE 'SKIP_DISPATCH=\$\([^`]*\)' | head -1)
    printf '%s' "$line"
}

# The inner command only, for the static shape assertions (PO-1*).
d2099p_extract_cmd() {
    local f="$1" line
    line=$(d2099p_section_line "$f" \
        | grep -oE 'bash "\$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip"[^`]*' | head -1)
    [ -n "$line" ] || { echo ""; return; }
    line="${line%% | tail*}"
    line="${line%)}"
    printf '%s' "$line"
}

# --- the signals FILE, which is now the only channel the judged csv travels on ---
# #2099 PO-INJ removed the `--signals <csv-or-empty>` splice slot from CI-C1b/A3a.
# The orchestrator Writes the judged csv (Write tool, never Bash) to the fixed path
# `<PLANS_DIR>/$SESSION_ID-complexity-signals.txt`, and the documented command line
# carries `--signals-file <that path>` — a constant shape no judge text can reach.
# These helpers simulate exactly that Write step, so every case below runs the
# skill's line VERBATIM apart from the `<PLANS_DIR>` / `<true|false>` slots the
# skill itself marks as fill-in.
D2099P_PLANS=""
d2099p_plans_dir() {
    if [ -z "$D2099P_PLANS" ]; then
        D2099P_PLANS="$TMPDIR_BASE/producer-plans"
        mkdir -p "$D2099P_PLANS"
    fi
    printf '%s' "$D2099P_PLANS"
}

# The orchestrator's Write-tool step. Content goes in raw and unquoted — no
# escaping, no shell involved — which is what makes the injection cases below a
# test of the DESIGN rather than of this harness's quoting.
d2099p_write_signals_file() {
    local sid="$1" csv="$2" dir
    dir=$(d2099p_plans_dir)
    printf '%s\n' "$csv" > "$dir/$sid-complexity-signals.txt"
}

# Fill the skill's own `<placeholder>` slots without touching anything else.
# `<PLANS_DIR>` is the only slot the csv path is built from; the csv itself is
# never substituted into the command, so no payload can be re-quoted into
# something the skill never wrote.
d2099p_fill_cmd() {
    local cmd="$1" c1="$2" c2="$3" dir
    dir=$(d2099p_plans_dir)
    printf '%s' "$cmd" | sed -E \
        -e "s#<PLANS_DIR>#$dir#g" \
        -e "s/--so-c1 <[^>]*>/--so-c1 $c1/" \
        -e "s/--so-c2 <[^>]*>/--so-c2 $c2/"
}

# Guard shared by every runner: the assertions below all measure an empty string
# if the documented line lost its `--signals-file "<PLANS_DIR>/..."` slot, so an
# absent slot must be a NAMED failure, never a silent no-op (the pre-#2099
# PO-INJ-0 "unattributable" result this replaces).
d2099p_signals_file_slot() {
    case "$1" in
        *'--signals-file "<PLANS_DIR>/$SESSION_ID-complexity-signals.txt"'*) printf 'ok' ;;
        *) printf '__NO_SIGNALS_FILE_SLOT__' ;;
    esac
}

# Execute the skill's assignment UNCHANGED and print what `$SKIP_DISPATCH` holds
# afterwards. No prefix stripping and no normalization: if the wrapper prints
# `SKIP_DISPATCH=advanced` while the skill's branch compares against a bare
# `advanced`, the two never meet and this suite must say so.
d2099p_run_producer() {
    local f="$1" sid="$2" signals="$3" c1="${4:-true}" c2="${5:-true}" cmd slot
    cmd=$(d2099p_extract_assignment "$f")
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    slot=$(d2099p_signals_file_slot "$cmd")
    [ "$slot" = "ok" ] || { echo "$slot"; return; }
    d2099p_write_signals_file "$sid" "$signals"
    cmd=$(d2099p_fill_cmd "$cmd" "$c1" "$c2")
    # Run from the fixture dir, never the worktree: a `<placeholder>` this fixture
    # does not fill would be read by the shell as a redirect and drop stray files
    # in $PWD (rules/test/fixture-isolation.md).
    mkdir -p "$TMPDIR_BASE/producer-cwd"
    (cd "$TMPDIR_BASE/producer-cwd" && AGENTS_CONFIG_DIR="$AGENTS_DIR" SESSION_ID="$sid" \
        run_with_timeout bash -c "$cmd"'
printf "%s" "$SKIP_DISPATCH"' 2>/dev/null)
}

# The DISPATCH BRANCH itself, as CI-C1c / A3b write it: a comparison of
# `$SKIP_DISPATCH` against the bare tokens. Run in the same shell as the
# assignment so the variable the skill sets is the variable the branch reads.
d2099p_run_dispatch_branch() {
    local f="$1" sid="$2" signals="$3" c1="${4:-true}" c2="${5:-true}" cmd slot
    cmd=$(d2099p_extract_assignment "$f")
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    slot=$(d2099p_signals_file_slot "$cmd")
    [ "$slot" = "ok" ] || { echo "$slot"; return; }
    d2099p_write_signals_file "$sid" "$signals"
    cmd=$(d2099p_fill_cmd "$cmd" "$c1" "$c2")
    mkdir -p "$TMPDIR_BASE/producer-cwd"
    (cd "$TMPDIR_BASE/producer-cwd" && AGENTS_CONFIG_DIR="$AGENTS_DIR" SESSION_ID="$sid" \
        run_with_timeout bash -c "$cmd"'
case "$SKIP_DISPATCH" in
  no-skip)        printf "branch:no-skip" ;;
  advanced)       printf "branch:advanced" ;;
  need-judgment)  printf "branch:need-judgment" ;;
  *)              printf "branch:NO_MATCH[%s]" "$SKIP_DISPATCH" ;;
esac' 2>/dev/null)
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
# string if the skill carries no runnable line, so the line is pinned first — and
# pinned to the signals-only contract (detail.md P4), not merely to being present.
d2099p_commands_are_real() {
    local name step target f cmd
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        # PO-0: the bound itself, before anything is extracted through it.
        d2099_assert_section_cli_unique "PO-0" "$step" "$f" "record-complexity-and-skip"
        cmd=$(d2099p_extract_cmd "$f")
        if [ -z "$cmd" ]; then
            fail "PO-1 $step carries no extractable record-complexity-and-skip command line"
            continue
        fi
        pass "PO-1 $step carries an extractable record-complexity-and-skip command line"
        assert_contains "PO-1a $step passes the session through" '--session "$SESSION_ID"' "$cmd"
        # PO-1b/b1/b2 are the #2099 PO-INJ contract in static form: the judged csv
        # reaches the CLI by FILE at a fixed path, and the old splice slot — the
        # thing every injection payload below used to travel through — is gone.
        assert_contains "PO-1b $step passes the judged csv by file" "--signals-file" "$cmd"
        assert_not_contains "PO-1b1 $step carries no literal --signals <csv> splice slot (PO-INJ)" \
            "--signals <" "$cmd"
        assert_contains "PO-1b2 $step names the documented fixed signals-file path" \
            '--signals-file "<PLANS_DIR>/$SESSION_ID-complexity-signals.txt"' "$cmd"
        assert_not_contains "PO-1c $step no longer passes --verdict" "--verdict" "$cmd"
        assert_contains "PO-1d $step names its own skip target" "--target $target" "$cmd"
        assert_contains "PO-1e $step settles the skip in the same call" "--advance" "$cmd"
        # The capture itself, not just the command: PO-3/PO-3a execute this line
        # verbatim, so a skill that stopped assigning to SKIP_DISPATCH (or dropped
        # the `| tail -1`) must be caught here rather than measured as an empty run.
        local asn
        asn=$(d2099p_extract_assignment "$f")
        assert_contains "PO-1f $step captures the wrapper's output into \$SKIP_DISPATCH" \
            'SKIP_DISPATCH=$(' "$asn"
        assert_contains "PO-1g $step keeps only the wrapper's last line" "| tail -1" "$asn"
    done <<EOF
$D2099P_PRODUCERS
EOF

    # CPR-ORTH: the two write points are symmetric, so the two extracted lines must
    # be the SAME command. A drift here is how one write point silently keeps an
    # old contract while the other moves.
    local a b
    a=$(d2099p_extract_cmd "$(d2099p_skill_file clarify-intent)")
    b=$(d2099p_extract_cmd "$(d2099p_skill_file workflow-init)")
    if [ -z "$a" ] || [ -z "$b" ]; then
        fail "PO-2 symmetry unattributable: at least one write point has no extractable command"
    else
        assert_eq "PO-2 CI-C1b and A3a issue the identical wrapper command (CPR-ORTH)" "$a" "$b"
    fi
}

# PO-3..: run each skill's own line for the three signal shapes the judge can
# produce — zero signals, several signals, and the undecidable token — and assert
# what was PERSISTED, what the stages DERIVE, and how the skip dispatched.
d2099p_producer_scenarios() {
    local name step target f label sid row signals want_dispatch want_levels want_raw want_skip
    # scenario | signals | dispatch | detail/write_tests/write_code | raw signals | skip record
    local SCENARIOS='empty||advanced|low/low/low|[]|present:true
multi|S2-architecture,S6-long-plan|need-judgment|high/high/high|["S2-architecture","S6-long-plan"]|absent
undecidable|S0-undecidable|need-judgment|high/high/high|["S0-undecidable"]|absent'

    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        while IFS='|' read -r label signals want_dispatch want_levels want_raw want_skip; do
            [ -n "$label" ] || continue
            sid=$(new_session "prod-$name-$label")
            assert_eq "PO-3 $step [$label] the skill's own assignment leaves \$SKIP_DISPATCH holding '$want_dispatch' verbatim" \
                "$want_dispatch" "$(d2099p_run_producer "$f" "$sid" "$signals")"
            # A fresh session: the branch re-runs the assignment, and PO-4 below
            # pins the original session to exactly one recorded event.
            assert_eq "PO-3a $step [$label] ... so the documented branch on the bare token actually takes the '$want_dispatch' arm" \
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
# The third site that turns a judge line into a `--signals` argument (the others
# are consumer-fallback-cases.sh and live-e2e-cases.sh). PO-3's `empty` row starts
# from an already-empty csv, so it never exercises the translation at all — yet
# CI-C1b/A3a receive `SIGNALS: none` from the judge, not an empty string. Both
# halves are asserted: the translated marker records the zero-signal evaluation
# and auto-advances, and the UNtranslated literal is persisted as an unrecognized
# token routing undecidable-high — which is what makes the translation load-bearing
# rather than cosmetic (round-9 C1).
d2099p_zero_signal_marker() {
    local name step target f sid csv
    csv=$(d2099_csv_for_cli "none")
    assert_eq "PO-8 the judge's zero-signal marker translates to the CLI's empty csv" "" "$csv"
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")

        sid=$(new_session "prodnone-$name")
        assert_eq "PO-8a $step: a translated 'SIGNALS: none' judgment leaves \$SKIP_DISPATCH holding 'advanced'" \
            "advanced" "$(d2099p_run_producer "$f" "$sid" "$csv")"
        assert_eq "PO-8b $step: ... persisting the zero-signal evaluation, not an undecidable one" \
            "n=1 level=low signals=[] levels=low/low/low" "$(d2099p_raw_event "$sid")"
        assert_eq "PO-8c $step: ... and the three stages read back low" \
            "low/low/low" "$(d2099p_stage_levels "$sid")"

        # The contrast. Without it PO-8b would also pass on a wrapper that maps
        # every unrecognized token to the zero-signal record — the silent-low path.
        sid=$(new_session "prodnonelit-$name")
        d2099p_run_producer "$f" "$sid" "none" >/dev/null
        assert_eq "PO-8d $step: the UNtranslated literal 'none' is kept verbatim and routes undecidable-high" \
            "n=1 level=high signals=[\"none\"] levels=high/high/high" "$(d2099p_raw_event "$sid")"
        assert_eq "PO-8e $step: ... so no outline skip is auto-advanced off a marker nobody translated" \
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
        assert_eq "PO-7 $step: --so-c1 false leaves \$SKIP_DISPATCH holding a bare no-skip even on a zero-signal evaluation" \
            "no-skip" "$(d2099p_run_producer "$f" "$sid" "" false true)"
        assert_eq "PO-7c $step: ... and the documented branch takes the no-skip arm" \
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

# --- PO-INJ: the producer boundary itself -------------------------------------
# Pre-#2099 the judge's csv was pasted into a `--signals <csv-or-empty>` slot on
# the skill's Bash line, so `$( )`, a backtick, `;`, `&&`, `|`, `>` or a quote
# break ran as command syntax. The fix deleted the slot: the csv is Written to a
# file and the line carries only a constant path. Each payload below goes into
# that file byte for byte and the documented line runs UNCHANGED, deliberately
# skipping the orchestrator's own `^[A-Za-z0-9,_-]*$` step — so what is proven is
# the CLI-side property: hostile bytes neither execute nor buy the cheap level.
#
# label | judge-produced csv. %NL% becomes a real newline, CANARY the canary path.
D2099P_INJECT='subshell|S1-multi-file,$(touch CANARY)
backtick|S1-multi-file,`touch CANARY`
semicolon|S1-multi-file; touch CANARY
amp|S1-multi-file && touch CANARY
pipe|S1-multi-file | touch CANARY
redirect|S1-multi-file > CANARY
newline|S1-multi-file%NL%touch CANARY
quote-break|S1-multi-file"; touch CANARY; :"'

d2099p_run_injection() {
    local f="$1" sid="$2" payload="$3" cmd dir slot
    cmd=$(d2099p_extract_assignment "$f")
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    slot=$(d2099p_signals_file_slot "$cmd")
    [ "$slot" = "ok" ] || { echo "$slot"; return; }
    d2099p_write_signals_file "$sid" "$payload"
    cmd=$(d2099p_fill_cmd "$cmd" true true)
    dir="$TMPDIR_BASE/producer-injection-cwd"
    mkdir -p "$dir"
    (cd "$dir" && AGENTS_CONFIG_DIR="$AGENTS_DIR" SESSION_ID="$sid" \
        run_with_timeout bash -c "$cmd"'
printf "%s" "$SKIP_DISPATCH"' 2>&1)
}

# A payload that escapes runs its canary; one that is merely rejected does not.
# Either outcome is safe ONLY if nothing shell-significant ran and no evaluation
# was persisted claiming the cheap level — those are the two ways #2099's write
# point could hand a hostile judge control of routing or of the machine.
d2099p_injection_cases() {
    local name step target f label payload sid canary dir out lvl
    dir="$TMPDIR_BASE/producer-injection-canary"
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        while IFS='|' read -r label payload; do
            [ -n "$label" ] || continue
            mkdir -p "$dir"
            canary="$dir/pwned-$name-$label"
            rm -f "$canary"
            payload=${payload//CANARY/$canary}
            payload=${payload//%NL%/$'\n'}
            sid=$(new_session "prodinj-$name-$label")
            out=$(d2099p_run_injection "$f" "$sid" "$payload")
            case "$out" in
                __NO_COMMAND__|__NO_SIGNALS_FILE_SLOT__)
                    fail "PO-INJ-0 $step [$label] unattributable: the skill carries no runnable --signals-file line to drive the payload through ($out)"
                    continue ;;
            esac
            if [ -e "$canary" ]; then
                fail "PO-INJ-1 $step [$label] SHELL ESCAPE: the judge-produced csv executed the canary command through the documented wrapper line"
            else
                pass "PO-INJ-1 $step [$label] the hostile csv executed no injected command"
            fi
            lvl=$(d2099p_raw_event "$sid")
            case "$lvl" in
                __NO_EVENT__*) pass "PO-INJ-2 $step [$label] ... and persisted nothing (a safe rejection)" ;;
                *level=high*)  pass "PO-INJ-2 $step [$label] ... or persisted a fail-high evaluation ($lvl)" ;;
                *) fail "PO-INJ-2 $step [$label] a hostile csv produced [$lvl] — neither a rejection nor a fail-high, so a hostile judge line steers routing to the cheap path" ;;
            esac
        done <<INJ
$D2099P_INJECT
INJ
    done <<EOF
$D2099P_PRODUCERS
EOF
}

# PO-INJ-3: the WRITE step the skills prescribe. PO-INJ-1/2 prove the CLI side is
# safe even with the guard skipped; this pins the guard itself, so a later edit
# cannot quietly drop the Write-tool-not-Bash rule or the charset substitution.
d2099p_write_step_documented() {
    local name step target f sec
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        f=$(d2099p_skill_file "$name")
        sec=$(d2099_skill_section "$f" "$step")
        assert_contains "PO-INJ-3 $step writes the judged csv with the Write tool, never Bash" \
            "Write tool" "$sec"
        assert_contains "PO-INJ-3a $step forbids splicing the judged csv into a Bash command" \
            "Never splice" "$sec"
        assert_contains "PO-INJ-3b $step substitutes S0-undecidable on a csv outside the safe charset" \
            'S0-undecidable' "$sec"
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
    out=$(AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout bash "$BIN_RECORD_SKIP" \
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
    out=$(AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout bash "$BIN_RECORD_SKIP" \
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
d2099p_injection_cases
d2099p_write_step_documented
d2099p_signals_flag_arity
d2099p_signals_file_round_trip
