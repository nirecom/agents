#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/answer-cases.sh — P2-P5, P12-P14.
# mark records "asked" for one session; answer records the verb, then never-ask writes the
# per-host record and calibrate runs <cwd>/bin/calibrate-test-parallelism.sh with the gate open.
# Relies on probe-cases.sh (sourced earlier) for DEFAULT_LINE.

case_begin "asked-once-per-session" "skills/run-tests/scripts/mark-calibration-asked.sh"

# ── P12 mark alone: a single asked_at line; this session gets notice, others ask ─
C12="$TMPROOT/cwd-p12"; mk_cwd "$C12" "$DEFAULT_LINE"
P12C="$TMPROOT/p12-cache"; mkdir -p "$P12C"
mark sid-p12 "$P12C"
ck "P12 mark: exit 0" "0" "$RC"
_m="$(marker_of sid-p12)"
[ -f "$_m" ] && pass "P12 marker file exists under <sid>.control" || fail "P12 marker missing" "path=$_m"
ck "P12 marker holds one asked_at line" "1" "$(grep -c '^asked_at=' "$_m" 2>/dev/null || echo 0)"
ck "P12 marker has no other lines" "1" "$(grep -c . "$_m" 2>/dev/null || echo 0)"
probe "$C12" sid-p12 "$P12C"
ck "P12 same session after mark: decision=notice" "notice" "$(kv decision)"
ck "P12 notice: reason=missing" "missing" "$(kv reason)"
probe "$C12" sid-p12-other "$P12C"
ck "P12 another session: decision=ask" "ask" "$(kv decision)"
[ ! -e "$P12C/calibration-never-ask.conf" ] && pass "P12 mark writes no never-ask record" || fail "P12 mark wrote a never-ask record"
case_ran P12

# ── P13 mark writes only the marker; refusals are reported, not swallowed ───
P13C="$TMPROOT/p13-cache"; mkdir -p "$P13C"
_before="$(content_sig "$P13C")"
mark sid-p13 "$P13C"
ck "P13 mark: exit 0" "0" "$RC"
ck "P13 mark leaves the cache untouched" "$_before" "$(content_sig "$P13C")"
ck "P13 control dir holds only the marker" "./calibration-asked.txt" \
    "$( (cd "$CLAUDE_WORKFLOW_DIR/sid-p13.control" 2>/dev/null && find . -type f) | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
run_script "$MARK" "$P13C" --
ck "P13 mark without --session: exit 2" "2" "$RC"
P13F="$TMPROOT/p13-workflow-is-a-file"; printf 'x\n' > "$P13F"
run_script "$MARK" "$P13C" "CLAUDE_WORKFLOW_DIR=$P13F" -- --session sid-p13b
ck "P13 unwritable control dir: exit 1" "1" "$RC"
[ "$RC" = "1" ] && [ -n "$ERR" ] && pass "P13 unwritable control dir: stderr explains the exit 1" || fail "P13 unwritable control dir: no exit-1 explanation on stderr" "rc=$RC"
case_ran P13

case_end

case_begin "defer-turns-ask-into-notice" "skills/run-tests/scripts/answer-calibration.sh"

# ── P2 mark then defer: notice for this session, ask for the next ───────────
C2="$TMPROOT/cwd-p2"; mk_cwd "$C2" "$DEFAULT_LINE"
P2C="$TMPROOT/p2-cache"; mkdir -p "$P2C"
mark sid-p2 "$P2C"
answer defer "$C2" sid-p2 "$P2C"
ck "P2 answer defer: exit 0" "0" "$RC"
grep -qx 'answer=defer' "$(marker_of sid-p2)" 2>/dev/null && pass "P2 marker records answer=defer" || fail "P2 marker lacks answer=defer"
probe "$C2" sid-p2 "$P2C"
ck "P2 same session after defer: decision=notice" "notice" "$(kv decision)"
probe "$C2" sid-p2-next "$P2C"
ck "P2 next session: decision=ask again" "ask" "$(kv decision)"
[ ! -e "$P2C/calibration-never-ask.conf" ] && pass "P2 defer writes no never-ask record" || fail "P2 defer wrote a never-ask record"
[ ! -e "$C2/cal.log" ] && pass "P2 defer never launches the calibrator" || fail "P2 defer launched the calibrator"
case_ran P2

# ── P3 no verb leaves the same session at ask, even without a prior mark ────
C3="$TMPROOT/cwd-p3"; mk_cwd "$C3" "$DEFAULT_LINE"
P3C="$TMPROOT/p3-cache"; mkdir -p "$P3C"
answer defer "$C3" sid-p3-defer "$P3C"
probe "$C3" sid-p3-defer "$P3C"
ck "P3 defer without mark: decision=notice" "notice" "$(kv decision)"
printf '5\n' > "$C3/cal.rc"
answer calibrate "$C3" sid-p3-cal "$P3C"
ck "P3 calibrate exits 5: passed through" "5" "$RC"
probe "$C3" sid-p3-cal "$P3C"
ck "P3 failed calibrate in this session: decision=notice" "notice" "$(kv decision)"
P3N="$TMPROOT/p3-never-cache"; mkdir -p "$P3N"
answer never-ask "$C3" sid-p3-never "$P3N"
ck "P3 never-ask without mark: exit 0" "0" "$RC"
probe "$C3" sid-p3-never "$P3N"
ck "P3 never-ask: decision=none reason=never-ask" "none/never-ask" "$(kv decision)/$(kv reason)"
rm -f "$P3N/calibration-never-ask.conf"
probe "$C3" sid-p3-never "$P3N"
ck "P3 never-ask record removed: the session marker still gives notice" "notice" "$(kv decision)"
case_ran P3

case_end

case_begin "never-ask-writes-the-host-record" "skills/run-tests/scripts/answer-calibration.sh"

# ── P4 never-ask writes a 3-line record atomically; the next session is silent ─
C4="$TMPROOT/cwd-p4"; mk_cwd "$C4" "$DEFAULT_LINE"
P4C="$TMPROOT/p4-cache"
mark sid-p4 "$P4C"
answer never-ask "$C4" sid-p4 "$P4C"
ck "P4 never-ask: exit 0" "0" "$RC"
_r="$P4C/calibration-never-ask.conf"
ck "P4 record has three lines" "3" "$(grep -c . "$_r" 2>/dev/null || echo 0)"
ck "P4 line 1 is schema=1" "schema=1" "$(sed -n 1p "$_r" 2>/dev/null)"
ck "P4 line 2 is this host" "host_id=$HID" "$(sed -n 2p "$_r" 2>/dev/null)"
grep -Eq '^recorded_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$' "$_r" 2>/dev/null \
    && pass "P4 recorded_at is an ISO-8601 timestamp" || fail "P4 recorded_at missing or not ISO-8601" "line3=$(sed -n 3p "$_r" 2>/dev/null)"
ck "P4 no temp file left behind" "" "$( (cd "$P4C" 2>/dev/null && ls -1 | grep '\.tmp$') | tr '\n' ' ')"
probe "$C4" sid-p4-next "$P4C"
ck "P4 next session: decision=none reason=never-ask" "none/never-ask" "$(kv decision)/$(kv reason)"
[ ! -e "$C4/cal.log" ] && pass "P4 never-ask never launches the calibrator" || fail "P4 never-ask launched the calibrator"
P4F="$TMPROOT/p4-cache-is-a-file"; printf 'x\n' > "$P4F"
answer never-ask "$C4" sid-p4-fail "$P4F"
ck "P4 record cannot be written: exit 1" "1" "$RC"
case_ran P4

case_end

case_begin "repeat-runs-are-idempotent" "skills/run-tests/scripts/answer-calibration.sh"

# ── I1 mark twice, never-ask twice: one file each, whole lines only, no temp files ─
CI1="$TMPROOT/cwd-i1"; mk_cwd "$CI1" "$DEFAULT_LINE"
I1C="$TMPROOT/i1-cache"; mkdir -p "$I1C"
_iso='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?'
mark sid-i1 "$I1C"; _rc1="$RC"; _first1="$(kv first)"
mark sid-i1 "$I1C"
ck "I1 mark twice: both exit 0" "0/0" "$_rc1/$RC"
ck "I1 mark twice: first call prints first=yes, second first=no" "yes/no" "$_first1/$(kv first)"
_m="$(marker_of sid-i1)"
ck "I1 mark twice: the control dir holds the one marker, no temp file" "./calibration-asked.txt" \
    "$( (cd "$CLAUDE_WORKFLOW_DIR/sid-i1.control" 2>/dev/null && find . -type f) | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
ck "I1 mark twice: two whole asked_at lines, nothing else, newline-terminated" "2/2/yes" \
    "$(grep -c . "$_m" 2>/dev/null)/$(grep -Ecx "asked_at=$_iso" "$_m" 2>/dev/null)/$(ends_nl "$_m")"
answer never-ask "$CI1" sid-i1 "$I1C"; _rc1="$RC"
answer never-ask "$CI1" sid-i1 "$I1C"
ck "I1 never-ask twice: both exit 0" "0/0" "$_rc1/$RC"
_r="$I1C/calibration-never-ask.conf"
ck "I1 never-ask twice: still exactly schema/host_id/recorded_at" "3/schema=1/host_id=$HID/yes/yes" \
    "$(grep -c . "$_r" 2>/dev/null)/$(sed -n 1p "$_r" 2>/dev/null)/$(sed -n 2p "$_r" 2>/dev/null)/$(grep -Eqx "recorded_at=$_iso" "$_r" 2>/dev/null && echo yes || echo no)/$(ends_nl "$_r")"
ck "I1 never-ask twice: the cache holds the record only, no *.tmp" "./calibration-never-ask.conf" \
    "$( (cd "$I1C" 2>/dev/null && find . -type f) | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
ck "I1 never-ask twice: marker gained one whole answer line per run" "4/2/yes" \
    "$(grep -c . "$_m" 2>/dev/null)/$(grep -cx 'answer=never-ask' "$_m" 2>/dev/null)/$(ends_nl "$_m")"
probe "$CI1" sid-i1-next "$I1C"
ck "I1 after the repeats: next session decision=none reason=never-ask" "none/never-ask" "$(kv decision)/$(kv reason)"
case_ran I1

case_end

case_begin "calibrate-runs-with-the-gate-open" "skills/run-tests/scripts/answer-calibration.sh"

# ── P5 calibrate: RUN_CALIBRATION=1, cwd=<cwd>, no args, exit code passed through ─
C5="$TMPROOT/cwd-p5"; mk_cwd "$C5" "$DEFAULT_LINE"
C5P="$(cd "$C5" && pwd -P)"
answer calibrate "$C5" sid-p5
ck "P5 calibrator exit 0: answer exits 0" "0" "$RC"
ck "P5 calibrator sees the gate open" "RUN_CALIBRATION=1" "$(grep '^RUN_CALIBRATION=' "$C5/cal.log" 2>/dev/null | head -n 1)"
ck "P5 calibrator runs from --cwd" "pwd=$C5P" "$(grep '^pwd=' "$C5/cal.log" 2>/dev/null | head -n 1)"
ck "P5 calibrator gets no arguments" "args=0" "$(grep '^args=' "$C5/cal.log" 2>/dev/null | head -n 1)"
grep -qx 'answer=calibrate' "$(marker_of sid-p5)" 2>/dev/null && pass "P5 marker records answer=calibrate" || fail "P5 marker lacks answer=calibrate"
printf '5\n' > "$C5/cal.rc"
answer calibrate "$C5" sid-p5
ck "P5 calibrator exit 5: passed through" "5" "$RC"
C5M="$TMPROOT/cwd-p5-no-calibrator"; mk_cwd "$C5M" "$DEFAULT_LINE"; rm -f "$C5M/bin/calibrate-test-parallelism.sh"
answer calibrate "$C5M" sid-p5m
ck "P5 calibrator missing: exit 3" "3" "$RC"
C5D="$TMPROOT/cwd-p5-other-verbs"; mk_cwd "$C5D" "$DEFAULT_LINE"
answer defer "$C5D" sid-p5d "$TMPROOT/p5-cache-d"
answer never-ask "$C5D" sid-p5d "$TMPROOT/p5-cache-n"
[ ! -e "$C5D/cal.log" ] && pass "P5 defer and never-ask never launch the calibrator" || fail "P5 a non-calibrate verb launched the calibrator"
case_ran P5

case_end

case_begin "effective-value-follows-the-record" "skills/run-tests/scripts/probe-calibration.sh"

# ── P14 after a calibrate run the probe reports the new record's value ──────
C14="$TMPROOT/cwd-p14"; mk_cwd "$C14" "$DEFAULT_LINE"
probe "$C14" sid-p14
ck "P14 before: default/4/na, decision=ask" "default/4/na/ask" "$(kv source)/$(kv max_jobs)/$(kv os_match)/$(kv decision)"
printf '%s\n' "max_jobs_per_host=6 source=measured" > "$C14/cal.line"
answer calibrate "$C14" sid-p14
ck "P14 calibrate: exit 0" "0" "$RC"
probe "$C14" sid-p14
ck "P14 after: measured/6/yes, decision=none reason=calibrated" "measured/6/yes/none/calibrated" \
    "$(kv source)/$(kv max_jobs)/$(kv os_match)/$(kv decision)/$(kv reason)"
printf '%s\n' "max_jobs_per_host=6 source=measured measured_on=Linux/0.0.0-p14 now=Linux/6.0" > "$C14/status.line"
probe "$C14" sid-p14-b
ck "P14 os changed later: measured/6/no, decision=ask" "measured/6/no/ask" "$(kv source)/$(kv max_jobs)/$(kv os_match)/$(kv decision)"
printf '%s\n' "$DEFAULT_LINE" > "$C14/status.line"
probe "$C14" sid-p14-c
ck "P14 record gone: default/4/na" "default/4/na" "$(kv source)/$(kv max_jobs)/$(kv os_match)"
case_ran P14

case_end

grp_done answer-cases.sh
