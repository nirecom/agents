#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/probe-cases.sh — P1, P6, P7, P8, A1 (probe).
# The probe reads only line 1 of <cwd>/bin/test-lanes-status.sh, the never-ask record, and
# the session marker; it prints six kv lines and writes nothing.

DEFAULT_LINE="max_jobs_per_host=4 source=default record=missing"
C_DEF="$TMPROOT/cwd-default"
mk_cwd "$C_DEF" "$DEFAULT_LINE"
[ -n "$HID" ] && pass "P precondition: run_all_host_id yields a host id" || fail "P precondition: run_all_host_id is empty"

case_begin "never-ask-record-decides" "skills/run-tests/scripts/probe-calibration.sh"

# ── P1 never-ask: only a valid record for this host turns ask into none ─────
P1C="$TMPROOT/p1"
na_rec "$P1C/match" "$HID"
probe "$C_DEF" sid-p1-a "$P1C/match"
ck "P1 record for this host: exit 0" "0" "$RC"
ck "P1 record for this host: decision=none" "none" "$(kv decision)"
ck "P1 record for this host: reason=never-ask" "never-ask" "$(kv reason)"
ck "P1 record for this host: notice is empty" "" "$(kv notice)"
na_rec "$P1C/other" "Other|x86_64|not-this-host"
probe "$C_DEF" sid-p1-a "$P1C/other"
ck "P1 record for another host: decision=ask" "ask" "$(kv decision)"
mkdir -p "$P1C/many"; { printf 'host_id=%s\n' "$HID"; for _i in 1 2 3 4 5 6 7 8; do printf 'pad%s=1\n' "$_i"; done; } > "$P1C/many/calibration-never-ask.conf"
probe "$C_DEF" sid-p1-a "$P1C/many"
ck "P1 record over 8 lines is invalid: decision=ask" "ask" "$(kv decision)"
mkdir -p "$P1C/dup"; printf 'host_id=%s\nhost_id=%s\n' "$HID" "$HID" > "$P1C/dup/calibration-never-ask.conf"
probe "$C_DEF" sid-p1-a "$P1C/dup"
ck "P1 duplicate host_id is invalid: decision=ask" "ask" "$(kv decision)"
mkdir -p "$P1C/empty"; printf 'schema=1\nhost_id=\nrecorded_at=x\n' > "$P1C/empty/calibration-never-ask.conf"
probe "$C_DEF" sid-p1-a "$P1C/empty"
ck "P1 empty host_id is invalid: decision=ask" "ask" "$(kv decision)"
case_ran P1

case_end

case_begin "probe-none-paths-and-effective-value" "skills/run-tests/scripts/probe-calibration.sh"

# ── P6 none paths; the effective-value lines are printed every time ─────────
C_NONE="$TMPROOT/cwd-no-status"; mkdir -p "$C_NONE"
probe "$C_NONE" sid-p6
ck "P6 no status tool: exit 0" "0" "$RC"
ck "P6 no status tool: decision=none" "none" "$(kv decision)"
ck "P6 no status tool: reason=no-lanes-status" "no-lanes-status" "$(kv reason)"
ck "P6 no status tool: source=unknown" "unknown" "$(kv source)"
ck "P6 no status tool: max_jobs empty" "" "$(kv max_jobs)"
ck "P6 no status tool: os_match=na" "na" "$(kv os_match)"
ck "P6 the six keys, each once (decision reason notice source max_jobs os_match)" \
    "decision max_jobs notice os_match reason source" \
    "$(printf '%s\n' "$OUT" | sed -n 's/^\([a-z_]*\)=.*/\1/p' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
ck "P6 output has six lines" "6" "$(printf '%s\n' "$OUT" | grep -c .)"
C_MEAS="$TMPROOT/cwd-measured"; mk_cwd "$C_MEAS" "max_jobs_per_host=5 source=measured"
probe "$C_MEAS" sid-p6
ck "P6 measured, same os: decision=none" "none" "$(kv decision)"
ck "P6 measured, same os: reason=calibrated" "calibrated" "$(kv reason)"
ck "P6 measured, same os: source=measured" "measured" "$(kv source)"
ck "P6 measured, same os: max_jobs=5" "5" "$(kv max_jobs)"
ck "P6 measured, same os: os_match=yes" "yes" "$(kv os_match)"
C_ENV="$TMPROOT/cwd-env"; mk_cwd "$C_ENV" "max_jobs_per_host=2 source=env"
probe "$C_ENV" sid-p6
ck "P6 env pin: decision=none" "none" "$(kv decision)"
ck "P6 env pin: reason=pinned" "pinned" "$(kv reason)"
ck "P6 env pin: source=env" "env" "$(kv source)"
ck "P6 env pin: os_match=na" "na" "$(kv os_match)"
C_DOT="$TMPROOT/cwd-dotenv"; mk_cwd "$C_DOT" "max_jobs_per_host=3 source=dotenv"
probe "$C_DOT" sid-p6
ck "P6 .env pin: reason=pinned" "pinned" "$(kv reason)"
ck "P6 .env pin: source=dotenv max_jobs=3" "dotenv/3" "$(kv source)/$(kv max_jobs)"
C_BAD="$TMPROOT/cwd-status-fails"; mk_cwd "$C_BAD" "$DEFAULT_LINE" 1
probe "$C_BAD" sid-p6
ck "P6 status exits 1: probe still exits 0" "0" "$RC"
ck "P6 status exits 1: decision=none" "none" "$(kv decision)"
ck "P6 status exits 1: reason=status-unavailable" "status-unavailable" "$(kv reason)"
ck "P6 status exits 1: source=unknown" "unknown" "$(kv source)"
C_CORR="$TMPROOT/cwd-corrupt"; mk_cwd "$C_CORR" "max_jobs_per_host=4 source=default record=corrupt"
probe "$C_CORR" sid-p6
ck "P6 default with record=corrupt: decision=ask, reason is the record value" "ask/corrupt" "$(kv decision)/$(kv reason)"
ck "P6 default: source=default max_jobs=4 os_match=na" "default/4/na" "$(kv source)/$(kv max_jobs)/$(kv os_match)"
# Table: status line 1 -> rc/source/max_jobs/os_match/decision (a glob; `*` where the spec is silent).
_t=0
while IFS='|' read -r name line want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    _t=$((_t + 1)); mk_cwd "$TMPROOT/cwd-p6t-$_t" "$line"
    probe "$TMPROOT/cwd-p6t-$_t" sid-p6t
    got="$RC/$(kv source)/$(kv max_jobs)/$(kv os_match)/$(kv decision)/$(kv_count decision)"
    case "$got" in $want) pass "P6 table $name ($got)" ;; *) fail "P6 table $name" "want=$want got=$(printf '%q' "$got")" ;; esac
done <<'TABLE'
default-missing  | max_jobs_per_host=4 source=default record=missing                 | 0/default/4/na/ask/1
measured-same-os | max_jobs_per_host=5 source=measured                                | 0/measured/5/yes/none/1
measured-os-diff | max_jobs_per_host=5 source=measured measured_on=A/1 now=A/2       | 0/measured/5/no/ask/1
env-pin          | max_jobs_per_host=2 source=env                                     | 0/env/2/na/none/1
no-max-jobs      | source=default record=missing                                      | 0/default//na/ask/1
empty-line       |                                                                    | 0/*//na/none/1
garbage-line     | %%% not a status line %%%                                          | 0/*//na/none/1
TABLE
ck "P6 table rows ran" "7" "$_t"
case_ran P6

case_end

case_begin "probe-is-read-only" "skills/run-tests/scripts/probe-calibration.sh"

# ── P7 the probe writes nothing and creates no control dir ──────────────────
P7C="$TMPROOT/p7-cache"; mkdir -p "$P7C"
# Self-test: the signature sees a same-path, same-size rewrite and ignores an mtime-only touch.
P7S="$TMPROOT/p7-sig-selftest"; mkdir -p "$P7S"; printf 'host_id=a\n' > "$P7S/f"
_s0="$(content_sig "$P7S")"; touch "$P7S/f"; _s1="$(content_sig "$P7S")"
printf 'host_id=b\n' > "$P7S/f"; _s2="$(content_sig "$P7S")"
ck "P7 self-test: content_sig ignores mtime, sees a same-path rewrite" "same/differs" \
    "$([ "$_s0" = "$_s1" ] && echo same || echo differs)/$([ "$_s1" = "$_s2" ] && echo same || echo differs)"
# Pre-seeded files a rewrite-in-place would alter: a run-all record, another session's marker,
# the cwd's status file (inside C_DEF), and the never-ask record of each path.
printf 'max_jobs_per_host=5\nsource=measured\n' > "$P7C/parallelism.conf"
mkdir -p "$CLAUDE_WORKFLOW_DIR/sid-p7-prior.control"
printf 'asked_at=2026-01-01T00:00:00Z\nanswer=defer\n' > "$CLAUDE_WORKFLOW_DIR/sid-p7-prior.control/calibration-asked.txt"
# Each "unchanged" check also pins the decision, so a probe that never ran cannot pass it.
na_rec "$P7C" "Other|x86_64|not-this-host"
_before="$(content_sig "$P7C" "$CLAUDE_WORKFLOW_DIR" "$C_DEF")"
probe "$C_DEF" sid-p7 "$P7C"
ck "P7 ask path: cache, workflow dir and cwd bytes unchanged" "$_before|ask" "$(content_sig "$P7C" "$CLAUDE_WORKFLOW_DIR" "$C_DEF")|$(kv decision)"
na_rec "$P7C" "$HID"
_before="$(content_sig "$P7C" "$CLAUDE_WORKFLOW_DIR" "$C_DEF")"
probe "$C_DEF" sid-p7 "$P7C"
ck "P7 never-ask path: cache, workflow dir and cwd bytes unchanged" "$_before|none" "$(content_sig "$P7C" "$CLAUDE_WORKFLOW_DIR" "$C_DEF")|$(kv decision)"
na_rec "$P7C" "Other|x86_64|not-this-host"
probe "$C_DEF" sid-p7 "$P7C"
ck "P7 no control dir for the session, no HOME write" "ask/absent/absent" \
    "$(kv decision)/$([ -e "$CLAUDE_WORKFLOW_DIR/sid-p7.control" ] && echo present || echo absent)/$([ -e "$HOME/.claude" ] && echo present || echo absent)"
case_ran P7

case_end

case_begin "notice-names-the-runnable-command" "skills/run-tests/scripts/lib/calibration-offer.sh"

# ── P8 the notice carries the full hint and the time limit ──────────────────
probe "$C_DEF" sid-p8
ck "P8 default/missing: the whole notice line" \
    "calibration: this host runs tests at the default max jobs per host (record missing); $NOTICE_TAIL" "$(kv notice)"
case "$(kv notice)" in
    *"RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"*"up to 90 min"*) pass "P8 notice has the hint and 'up to 90 min'" ;;
    *) fail "P8 notice lacks the hint or the time limit" "notice=$(printf '%q' "$(kv notice)")" ;;
esac
C_OS="$TMPROOT/cwd-os-mismatch"
mk_cwd "$C_OS" "max_jobs_per_host=5 source=measured measured_on=Windows/0.0.0-p8 now=Windows/10.0.26300"
probe "$C_OS" sid-p8
ck "P8 os mismatch: decision=ask" "ask" "$(kv decision)"
ck "P8 os mismatch: source=measured max_jobs=5 os_match=no" "measured/5/no" "$(kv source)/$(kv max_jobs)/$(kv os_match)"
case "$(kv notice)" in
    *"(measured on Windows/0.0.0-p8, now Windows/10.0.26300); $NOTICE_TAIL") pass "P8 os mismatch: notice names both versions and the hint" ;;
    *) fail "P8 os mismatch notice" "notice=$(printf '%q' "$(kv notice)")" ;;
esac
case_ran P8

case_end

case_begin "probe-argument-errors" "skills/run-tests/scripts/probe-calibration.sh"

# ── A1 argument errors exit 2 for all three scripts ─────────────────────────
run_script "$PROBE" "$CACHE" -- --cwd "$C_DEF"
ck "A1 probe without --session: exit 2" "2" "$RC"
run_script "$PROBE" "$CACHE" -- --session sid-a1
ck "A1 probe without --cwd: exit 2" "2" "$RC"
run_script "$PROBE" "$CACHE" -- --cwd "$C_DEF" --session sid-a1 --bogus
ck "A1 probe with an unknown argument: exit 2" "2" "$RC"
run_script "$PROBE" "$CACHE" -- --cwd "$C_DEF" --session
ck "A1 probe with --session lacking a value: exit 2" "2" "$RC"
run_script "$MARK" "$CACHE" --
ck "A1 mark without --session: exit 2" "2" "$RC"
run_script "$MARK" "$CACHE" -- --session sid-a1 --cwd "$C_DEF" --bogus
ck "A1 mark with an unknown argument: exit 2" "2" "$RC"
run_script "$ANSWER" "$CACHE" -- --cwd "$C_DEF" --session sid-a1
ck "A1 answer without a verb: exit 2" "2" "$RC"
run_script "$ANSWER" "$CACHE" -- rm-rf --cwd "$C_DEF" --session sid-a1
ck "A1 answer with an unknown verb: exit 2" "2" "$RC"
run_script "$ANSWER" "$CACHE" -- defer --session sid-a1
ck "A1 answer without --cwd: exit 2" "2" "$RC"
[ ! -e "$CLAUDE_WORKFLOW_DIR/sid-a1.control" ] && pass "A1 argument errors write no marker" || fail "A1 an argument error still wrote a marker"
[ ! -e "$C_DEF/cal.log" ] && pass "A1 argument errors never launch the calibrator" || fail "A1 an argument error launched the calibrator"
case_ran A1

case_end

grp_done probe-cases.sh
