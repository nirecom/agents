#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/mode-and-estimate-cases.sh — AC4, ES1, ES3 (#2687).
# AC4: the probe reads mode= and recalibrate= from status line 1 — mode=off silences the offer,
# a recalibrate advice takes the measured ask/notice path, a pin still answers none pinned.
# ES1: on ask (only) the probe runs <cwd>/bin/calibrate-test-parallelism.sh --dry-run and turns
# its `plan: estimate_total_s=<n>` line into estimate=<minutes>; any failure leaves it empty.
# ES3: that dry-run is bounded (bin/run-with-timeout.sh 30, else timeout 30, else no estimate).
# Relies on probe-cases.sh (sourced earlier) for DEFAULT_LINE.

# pr_line <name> <status-line-1> [sid] — a fresh fake worktree probed once; sets OUT/RC and
# PR_CWD (the worktree, for dry_calls).
PR_N=0; PR_CWD=""
pr_line() {
    PR_N=$((PR_N + 1)); PR_CWD="$TMPROOT/cwd-ac4-$PR_N-$1"
    mk_cwd "$PR_CWD" "$2"
    probe "$PR_CWD" "${3:-sid-ac4-$PR_N}"
}
# dkv — decision/reason, the most common pair below.
dkv() { printf '%s/%s' "$(kv decision)" "$(kv reason)"; }

case_begin "auto-config-off-silences-the-offer" "skills/run-tests/scripts/probe-calibration.sh"

# ── AC4 mode=off: none auto-config-off, whatever the record says ────────────
pr_line off-default "max_jobs_per_host=4 source=default record=missing mode=off"
ck "AC4 mode=off, no record: exit 0" "0" "$RC"
ck "AC4 mode=off, no record: none/auto-config-off" "none/auto-config-off" "$(dkv)"
ck "AC4 mode=off: notice and estimate empty" "|" "$(kv notice)|$(kv estimate)"
ck "AC4 mode=off: source/max_jobs still reported" "default/4" "$(kv source)/$(kv max_jobs)"
ck "AC4 mode=off: the dry-run is never launched" "0" "$(dry_calls "$PR_CWD")"
pr_line off-os "max_jobs_per_host=5 source=measured measured_on=A/1 now=A/2 mode=off"
ck "AC4 mode=off beats an OS-mismatched record: none/auto-config-off" "none/auto-config-off" "$(dkv)"
pr_line off-legacy "max_jobs_per_host=16 source=measured mode=off recalibrate=legacy-record"
ck "AC4 mode=off beats a recalibrate advice: none/auto-config-off" "none/auto-config-off" "$(dkv)"
pr_line off-env "max_jobs_per_host=6 source=env mode=off"
ck "AC4 mode=off with an env pin: decision=none" "none" "$(kv decision)"
pr_line on-default "max_jobs_per_host=4 source=default record=missing mode=on"
ck "AC4 mode=on, no record: ask/missing (unchanged)" "ask/missing" "$(dkv)"
pr_line on-measured "max_jobs_per_host=8 source=measured mode=on capped=logical-cpu-count"
ck "AC4 mode=on, measured, no advice (extra tokens ignored): none/calibrated" "none/calibrated" "$(dkv)"
ck "AC4 mode=on, measured: source/max_jobs/os_match" "measured/8/yes" "$(kv source)/$(kv max_jobs)/$(kv os_match)"
pr_line on-env "max_jobs_per_host=12 source=env mode=on"
ck "AC4 mode=on, env pin: none/pinned" "none/pinned" "$(dkv)"
pr_line on-dotenv "max_jobs_per_host=3 source=dotenv mode=on logical_cpus=unknown"
ck "AC4 mode=on, .env pin: none/pinned" "none/pinned" "$(dkv)"
case_ran AC4

case_end

case_begin "recalibrate-advice-asks" "skills/run-tests/scripts/probe-calibration.sh"

# ── AC4 recalibrate=<why> takes the measured ask/notice path ────────────────
for _why in legacy-record ladder-truncated cpu-count-changed; do
    pr_line "rc-$_why" "max_jobs_per_host=16 source=measured mode=on recalibrate=$_why"
    ck "AC4 recalibrate=$_why: decision=ask" "ask" "$(kv decision)"
    ck "AC4 recalibrate=$_why: source/max_jobs" "measured/16" "$(kv source)/$(kv max_jobs)"
    case "$(kv notice)" in
        *"$NOTICE_HINT"*) pass "AC4 recalibrate=$_why: the notice carries the runnable hint" ;;
        *) fail "AC4 recalibrate=$_why: notice lacks the hint" "notice=$(printf '%q' "$(kv notice)")" ;;
    esac
done
AC4M="$TMPROOT/ac4-marker-cache"; mkdir -p "$AC4M"
mk_cwd "$TMPROOT/cwd-ac4-rc-notice" "max_jobs_per_host=16 source=measured mode=on recalibrate=legacy-record"
mark sid-ac4-notice "$AC4M"
probe "$TMPROOT/cwd-ac4-rc-notice" sid-ac4-notice "$AC4M"
ck "AC4 recalibrate after this session was asked: decision=notice" "notice" "$(kv decision)"
ck "AC4 recalibrate, notice: no dry-run launched" "0" "$(dry_calls "$TMPROOT/cwd-ac4-rc-notice")"
probe "$TMPROOT/cwd-ac4-rc-notice" sid-ac4-notice-other "$AC4M"
ck "AC4 recalibrate, another session: decision=ask" "ask" "$(kv decision)"
# Hostile token values are data: one decision line, nothing executed.
AC4_PWN="$TMPROOT/ac4-pwned"
pr_line hostile "max_jobs_per_host=16 source=measured mode=\$(touch $AC4_PWN) recalibrate=\`touch $AC4_PWN\`"
ck "AC4 hostile mode=/recalibrate= values: exit 0, one decision line" "0/1" "$RC/$(kv_count decision)"
[ ! -e "$AC4_PWN" ] && pass "AC4 hostile mode=/recalibrate= values are never executed" || fail "AC4 a hostile status token was executed"
case_ran AC4

case_end

case_begin "estimate-from-the-dry-run" "skills/run-tests/scripts/probe-calibration.sh"

# ── ES1 ask runs the dry-run once, from <cwd>, and reports whole minutes ────
pr_line es-ask "$DEFAULT_LINE"
ck "ES1 ask: decision=ask, exit 0" "ask/0" "$(kv decision)/$RC"
ck "ES1 ask: 600 s -> estimate=10" "10" "$(kv estimate)"
ck "ES1 ask: exactly one dry-run launch" "1" "$(dry_calls "$PR_CWD")"
ck "ES1 ask: the dry-run runs from --cwd with only --dry-run" "pwd=$(cd "$PR_CWD" && pwd -P) args=--dry-run" "$(head -n 1 "$PR_CWD.dry.log" 2>/dev/null)"
[ ! -e "$PR_CWD/cal.log" ] && pass "ES1 ask: the measuring calibrator never runs" || fail "ES1 ask: the probe ran the calibrator without --dry-run"
# es_out <name> <dry.out text> [dry.rc] — ask path with a scripted dry-run.
es_out() {
    PR_N=$((PR_N + 1)); PR_CWD="$TMPROOT/cwd-es-$PR_N-$1"
    mk_cwd "$PR_CWD" "$DEFAULT_LINE"
    printf '%s\n' "$2" > "$PR_CWD/dry.out"
    [ -n "${3:-}" ] && printf '%s\n' "$3" > "$PR_CWD/dry.rc"
    probe "$PR_CWD" "sid-es-$PR_N"
}
es_out long $'calibrate: plan\nplan: estimate_total_s=3000'
ck "ES1 3000 s -> estimate=50" "50" "$(kv estimate)"
es_out short 'plan: estimate_total_s=90'
case "$(kv estimate)" in 1|2) pass "ES1 90 s -> estimate is a whole minute count ($(kv estimate))" ;; *) fail "ES1 90 s -> estimate" "estimate=$(printf '%q' "$(kv estimate)")" ;; esac
es_out rc1 'plan: estimate_total_s=600' 1
ck "ES1 dry-run exits 1: probe exit 0, still ask, estimate empty" "0/ask/" "$RC/$(kv decision)/$(kv estimate)"
es_out noline 'calibrate: dry run without a plan line'
ck "ES1 no estimate line: estimate empty, still ask" "/ask" "$(kv estimate)/$(kv decision)"
es_out alpha 'plan: estimate_total_s=12abc'
ck "ES1 non-numeric estimate: estimate empty" "" "$(kv estimate)"
ES_PWN="$TMPROOT/es-pwned"
es_out hostile "plan: estimate_total_s=\$(touch $ES_PWN)\`touch $ES_PWN\`"
ck "ES1 hostile estimate: estimate empty, one estimate line" "/1" "$(kv estimate)/$(kv_count estimate)"
[ ! -e "$ES_PWN" ] && pass "ES1 hostile dry-run output is never executed" || fail "ES1 hostile dry-run output was executed"
es_out injected-lines $'plan: estimate_total_s=600\ndecision=none\nestimate=999'
ck "ES1 extra dry-run lines never become probe output" "ask/1/10/1" "$(kv decision)/$(kv_count decision)/$(kv estimate)/$(kv_count estimate)"
pr_line es-nocal "$DEFAULT_LINE"
rm -f "$PR_CWD/bin/calibrate-test-parallelism.sh"
probe "$PR_CWD" sid-es-nocal
ck "ES1 no calibrator in --cwd: exit 0, ask, estimate empty" "0/ask/" "$RC/$(kv decision)/$(kv estimate)"
# none and notice never launch the dry-run.
pr_line es-measured "max_jobs_per_host=5 source=measured"
ck "ES1 none (calibrated): estimate empty, no dry-run" "none//0" "$(kv decision)/$(kv estimate)/$(dry_calls "$PR_CWD")"
pr_line es-env "max_jobs_per_host=2 source=env"
ck "ES1 none (pinned): estimate empty, no dry-run" "none//0" "$(kv decision)/$(kv estimate)/$(dry_calls "$PR_CWD")"
ESM="$TMPROOT/es-marker-cache"; mkdir -p "$ESM"
pr_line es-notice "$DEFAULT_LINE" sid-es-notice
_n_ask="$(dry_calls "$PR_CWD")"
mark sid-es-notice "$ESM"
probe "$PR_CWD" sid-es-notice "$ESM"
ck "ES1 notice: estimate empty, no further dry-run" "notice//$_n_ask" "$(kv decision)/$(kv estimate)/$(dry_calls "$PR_CWD")"
case_ran ES1

case_end

case_begin "estimate-dry-run-is-bounded" "skills/run-tests/scripts/probe-calibration.sh"

# ── ES3 the dry-run runs under a 30 s bound: run-with-timeout.sh, else timeout, else none ─
# es_rwt <name> [rc] — ask path with a <cwd>/bin/run-with-timeout.sh stub that logs its args
# to <cwd>.rwt.log and then runs the rest, or (with <rc>) exits <rc> without running anything.
es_rwt() {
    PR_N=$((PR_N + 1)); PR_CWD="$TMPROOT/cwd-es3-$PR_N-$1"
    mk_cwd "$PR_CWD" "$DEFAULT_LINE"
    printf '%s\n' '#!/usr/bin/env bash' 'd="$(cd "$(dirname "$0")/.." && pwd)"' \
        'printf "%s\n" "$*" >> "$d.rwt.log"' \
        '[ -f "$d/rwt.rc" ] && exit "$(cat "$d/rwt.rc")"' \
        'shift; exec "$@"' > "$PR_CWD/bin/run-with-timeout.sh"
    [ -n "${2:-}" ] && printf '%s\n' "$2" > "$PR_CWD/rwt.rc"
    probe "$PR_CWD" "sid-es3-$PR_N"
}
es_rwt bound
ck "ES3 run-with-timeout.sh present: ask, exit 0, estimate=10" "ask/0/10" "$(kv decision)/$RC/$(kv estimate)"
ck "ES3 the dry-run goes through the 30 s bound helper" "30 bash bin/calibrate-test-parallelism.sh --dry-run" \
    "$(head -n 1 "$PR_CWD.rwt.log" 2>/dev/null)"
ck "ES3 bound helper: exactly one dry-run launch" "1" "$(dry_calls "$PR_CWD")"
es_rwt stalled 124
ck "ES3 stalled dry-run (bound exits 124): probe exit 0, still ask, estimate empty" "0/ask/" "$RC/$(kv decision)/$(kv estimate)"
ck "ES3 stalled: the bound helper was called once" "1" "$(grep -c . "$PR_CWD.rwt.log" 2>/dev/null || echo 0)"
ck "ES3 stalled: the calibrator dry-run never ran" "0" "$(dry_calls "$PR_CWD")"
# No bound available: a PATH of wrappers without timeout, and no run-with-timeout.sh in --cwd.
# shellcheck source=../../lib/tool-shim-path.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/tool-shim-path.sh"
ES3_FULL="$(tsp_base_path "$TMPROOT/es3-path-full")"
ES3_NOTO="$(tsp_base_path "$TMPROOT/es3-path-notimeout" timeout)"
if [ -n "$ES3_FULL" ] && [ -n "$ES3_NOTO" ] && [ -x "$ES3_FULL/timeout" ]; then
    PR_CWD="$TMPROOT/cwd-es3-shim-control"; mk_cwd "$PR_CWD" "$DEFAULT_LINE"
    run_script "$PROBE" "$CACHE" "PATH=$ES3_FULL" -- --cwd "$PR_CWD" --session sid-es3-shim-control
    ck "ES3 control: the wrapper PATH with timeout still yields estimate=10" "ask/10/1" "$(kv decision)/$(kv estimate)/$(dry_calls "$PR_CWD")"
    PR_CWD="$TMPROOT/cwd-es3-nobound"; mk_cwd "$PR_CWD" "$DEFAULT_LINE"
    run_script "$PROBE" "$CACHE" "PATH=$ES3_NOTO" -- --cwd "$PR_CWD" --session sid-es3-nobound
    ck "ES3 no bound at all: probe exit 0, still ask, estimate empty" "0/ask/" "$RC/$(kv decision)/$(kv estimate)"
    ck "ES3 no bound at all: the dry-run is never launched unbounded" "0" "$(dry_calls "$PR_CWD")"
else
    skip "ES3 no-bound branch: tsp_base_path could not build a PATH with and without timeout here"
fi
case_ran ES3

case_end

grp_done mode-and-estimate-cases.sh
