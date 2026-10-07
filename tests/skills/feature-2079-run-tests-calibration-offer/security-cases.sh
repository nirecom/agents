#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/security-cases.sh — S1-S5.
# Hostile session ids, --cwd names, record contents and status output are data, never code,
# and never steer a write outside the session control dir. The host id never leaks.
# Relies on probe-cases.sh (sourced earlier) for DEFAULT_LINE and C_DEF.

case_begin "hostile-session-id" "skills/run-tests/scripts/mark-calibration-asked.sh"

# ── S1 a session id is validated before any path is built from it ───────────
S1D="$TMPROOT/s1"; mkdir -p "$S1D"
S1_PWN="$S1D/pwned"
# rc_in <list> — the script ran (126/127 mean it is missing) and exited with one of <list>.
rc_in() { case " $1 " in *" $RC "*) return 0 ;; esac; return 1; }
# Every id below fails the control-dir sid check, so no session control dir exists for it: a
# definite outcome is "no marker, control dir or temp file appears anywhere" whatever the rc.
# The spec leaves answer's rc open when its first marker write is refused, so 0/1/2 are accepted.
for _sid in '../evil' '..' 'a/../../evil' "\$(touch $S1_PWN)" "\`touch $S1_PWN\`" '.hidden' ''; do
    _q="$(printf '%q' "$_sid")"
    _sig="$(marker_sig)"
    mark "$_sid"
    rc_in "1 2" && pass "S1 mark refuses sid $_q (rc=$RC)" || fail "S1 mark sid $_q: want rc 1 or 2" "rc=$RC"
    ck "S1 mark sid $_q: no marker written anywhere" "$_sig" "$(marker_sig)"
    answer defer "$C_DEF" "$_sid"
    rc_in "0 1 2" && pass "S1 answer handles sid $_q without crashing (rc=$RC)" || fail "S1 answer sid $_q: want rc 0, 1 or 2" "rc=$RC"
    ck "S1 answer defer sid $_q (rc=$RC): no marker written anywhere" "$_sig" "$(marker_sig)"
    probe "$C_DEF" "$_sid"
    rc_in "0 2" && pass "S1 probe handles sid $_q (rc=$RC)" || fail "S1 probe sid $_q: want rc 0 or 2" "rc=$RC"
    ck "S1 probe sid $_q: nothing written" "$_sig" "$(marker_sig)"
done
[ ! -e "$S1_PWN" ] && pass "S1 no sid was executed" || fail "S1 a sid was executed"
[ ! -e "$(dirname "$CLAUDE_WORKFLOW_DIR")/evil.control" ] && [ ! -e "$TMPROOT/evil.control" ] && [ ! -e "$(dirname "$CLAUDE_WORKFLOW_DIR")/evil" ] \
    && pass "S1 no file escaped the workflow dir" || fail "S1 a traversal sid wrote outside the workflow dir"
ck "S1 nothing written in the workflow dir for invalid sids" "" \
    "$( (cd "$CLAUDE_WORKFLOW_DIR" 2>/dev/null && find . -name '*evil*' -o -name '*pwned*' -o -name '.hidden*') | tr '\n' ' ')"
case_ran S1

case_end

case_begin "hostile-cwd" "skills/run-tests/scripts/probe-calibration.sh"

# ── S2 --cwd with metacharacters is a path, nothing more ─────────────────────
S2_PWN="$TMPROOT/s2-pwned"
S2C="$TMPROOT/cwd s2 \$(touch $S2_PWN) \`touch $S2_PWN\` ;x"
mk_cwd "$S2C" "$DEFAULT_LINE"
probe "$S2C" sid-s2
ck "S2 metachar cwd: exit 0" "0" "$RC"
ck "S2 metachar cwd: its status is read (decision=ask)" "ask" "$(kv decision)"
answer calibrate "$S2C" sid-s2
ck "S2 metachar cwd: calibrator runs and exits 0" "0" "$RC"
[ -f "$S2C/cal.log" ] && pass "S2 calibrator ran inside the metachar cwd" || fail "S2 calibrator did not run inside the metachar cwd"
[ ! -e "$S2_PWN" ] && pass "S2 the cwd name was never executed" || fail "S2 the cwd name was executed"
probe "$TMPROOT/no-such-dir/../../etc" sid-s2
ck "S2 nonexistent / traversing cwd: decision=none" "none" "$(kv decision)"
answer calibrate "$TMPROOT/no-such-dir" sid-s2b
ck "S2 calibrate with a nonexistent cwd: exit 3 (no calibrator there)" "3" "$RC"
case_ran S2

case_end

case_begin "hostile-never-ask-record" "skills/run-tests/scripts/probe-calibration.sh"

# ── S3 a hostile host_id in the record is compared, never run ───────────────
S3_PWN="$TMPROOT/s3-pwned"
S3C="$TMPROOT/s3-cache"; mkdir -p "$S3C"
printf 'schema=1\nhost_id=$(touch %s)`touch %s`\nrecorded_at=x\n' "$S3_PWN" "$S3_PWN" > "$S3C/calibration-never-ask.conf"
probe "$C_DEF" sid-s3 "$S3C"
ck "S3 hostile record is inactive: decision=ask" "ask" "$(kv decision)"
[ ! -e "$S3_PWN" ] && pass "S3 hostile host_id is never executed" || fail "S3 hostile host_id was executed"
case_ran S3

case_end

case_begin "hostile-status-output" "skills/run-tests/scripts/probe-calibration.sh"

# ── S4 only line 1 of the status output is parsed, as data ──────────────────
S4_PWN="$TMPROOT/s4-pwned"
S4C="$TMPROOT/cwd-s4"
mk_cwd "$S4C" "max_jobs_per_host=4 source=default record=\$(touch $S4_PWN)\`touch $S4_PWN\`"
probe "$S4C" sid-s4
ck "S4 hostile record token: exit 0" "0" "$RC"
[ ! -e "$S4_PWN" ] && pass "S4 status line 1 is never executed" || fail "S4 status line 1 was executed"
ck "S4 one decision line only" "1" "$(kv_count decision)"
S4B="$TMPROOT/cwd-s4b"
mk_cwd "$S4B" "$DEFAULT_LINE"
printf '%s\n%s\n%s\n' "$DEFAULT_LINE" "decision=none" "max_jobs_per_host=9 source=env" > "$S4B/status.line"
probe "$S4B" sid-s4b
ck "S4 injected later lines are ignored: decision=ask" "ask" "$(kv decision)"
ck "S4 injected later lines are ignored: one decision line" "1" "$(kv_count decision)"
ck "S4 injected later lines are ignored: source/max_jobs from line 1" "default/4" "$(kv source)/$(kv max_jobs)"
case_ran S4

case_end

case_begin "host-id-never-printed" "skills/run-tests/scripts/answer-calibration.sh"

# ── S5 the host id (its digest) never appears on stdout or stderr ───────────
if [ -z "$HID_DIGEST" ]; then
    fail "S5 precondition: no host id digest to search for"
else
    S5C="$TMPROOT/s5-cache"
    _leak=""; _seen=""
    probe "$C_DEF" sid-s5 "$S5C"; _seen="$_seen$(kv decision)/"; case "$OUT$ERR" in *"$HID_DIGEST"*) _leak="$_leak probe-ask" ;; esac
    mark sid-s5 "$S5C"; _seen="$_seen$RC/"; case "$OUT$ERR" in *"$HID_DIGEST"*) _leak="$_leak mark" ;; esac
    answer never-ask "$C_DEF" sid-s5 "$S5C"; _seen="$_seen$RC/"; case "$OUT$ERR" in *"$HID_DIGEST"*) _leak="$_leak answer-never-ask" ;; esac
    probe "$C_DEF" sid-s5 "$S5C"; _seen="$_seen$(kv decision)/"; case "$OUT$ERR" in *"$HID_DIGEST"*) _leak="$_leak probe-never-ask" ;; esac
    answer defer "$C_DEF" sid-s5 "$S5C"; _seen="$_seen$RC"; case "$OUT$ERR" in *"$HID_DIGEST"*) _leak="$_leak answer-defer" ;; esac
    ck "S5 the scanned runs really ran (probe ask, mark 0, never-ask 0, probe none, defer 0)" "ask/0/0/none/0" "$_seen"
    ck "S5 no output carries the host id digest" "" "$_leak"
    grep -q "$HID_DIGEST" "$(marker_of sid-s5)" 2>/dev/null && fail "S5 the session marker carries the host id" || pass "S5 the session marker carries no host id"
fi
case_ran S5

case_end

grp_done security-cases.sh
