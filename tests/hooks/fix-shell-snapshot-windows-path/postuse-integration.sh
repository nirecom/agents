#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/postuse-integration.sh
# Tests: hooks/postuse-shell-snapshot-repair.js
# Tags: hook, shell-snapshot, posttooluse, posttoolusefailure, integration, scope:issue-specific, TL2
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher).
# The real hook on stdin over a fixture home, state dir and transcript: first / recheck / skip, wording
# per trigger, no re-run, other sessions' snapshots left alone; repair checks SKIP without real cygpath.
# TL3 gap (what this test does NOT catch):
# - Real CC firing PostToolUseFailure with error "Exit code 127\n…" after a Bash exit 127 (Step 11).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

PU_NOW="$(now_ms)"
PU_N=0
PU_WIN='C:\Windows\System32;C:\Windows'

# pu_home — fresh home with a transcript starting 60 s ago; sets PU_H, PU_D, PU_TR, PU_SID.
pu_home() {
  PU_N=$((PU_N + 1))
  PU_H="$SNAP_TMP/pu-$PU_N"
  PU_D="$PU_H/.claude/shell-snapshots"
  mkdir -p "$PU_D"
  PU_TR="$(np "$PU_H/transcript.jsonl")"
  write_transcript "$PU_H/transcript.jsonl" $((PU_NOW - 60000))
  PU_SID="pu-sid-$PU_N"
}
pu_name() { printf 'snapshot-bash-%s-%s.sh' "$((PU_NOW + $1))" "$2"; }

# pu_input <file> <event> <sid> <transcript> [error] — command would create $file.ran if re-run.
pu_input() {
  local err=""
  [ -n "${5:-}" ] && err=",\"error\":\"$5\""
  printf '{"hook_event_name":"%s","session_id":"%s","tool_name":"Bash","tool_input":{"command":"touch %s.ran"},"transcript_path":"%s"%s}' \
    "$2" "$3" "$(np "$1")" "$4" "$err" > "$1"
}

# pu_run <home> <event> <sid> [error] — runs the hook; sets PU_OUT (file) and PU_RC.
pu_run() {
  PU_N=$((PU_N + 1))
  PU_OUT="$SNAP_TMP/pu-out-$PU_N"
  pu_input "$PU_OUT.in" "$2" "$3" "$PU_TR" "${4:-}"
  HOME="$1" USERPROFILE="$1" run_with_timeout 30 node "$POSTUSE_HOOK" < "$PU_OUT.in" > "$PU_OUT" 2> "$PU_OUT.err"
  PU_RC=$?
}
pu_ctx() { json_get "$PU_OUT" hookSpecificOutput.additionalContext; }
pu_has() { case "$(pu_ctx)" in *"$1"*) return 0 ;; esac; return 1; }
pu_neutral_ok() {
  local c; c="$(pu_ctx)"
  case "$c" in *"exited with code 127"*|*"previous command"*|*"re-run"*|*"exiting 127"*) return 1 ;; esac
  case "$c" in *"PATH has been repaired"*) case "$c" in *"takes effect for subsequent Bash calls"*) return 0 ;; esac ;; esac
  return 1
}
pu_check() { if eval "$2"; then pass "postuse: $1"; else fail "postuse: $1" "rc=$PU_RC out=$(head -c 300 "$PU_OUT" 2>/dev/null)"; fi; }
pu_not_ran() { [ ! -e "$PU_OUT.in.ran" ]; }

if have_cygpath_host; then
  # --- first (PostToolUse): neutral wording, marker trigger first, never re-runs.
  pu_home; F="$PU_D/$(pu_name -30000 a)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "first PostToolUse repairs the snapshot" 'snap_is_ok "$F"'
  pu_check "first PostToolUse hookEventName" '[ "$(json_get "$PU_OUT" hookSpecificOutput.hookEventName)" = PostToolUse ]'
  pu_check "first PostToolUse neutral wording" 'pu_neutral_ok'
  pu_check "first PostToolUse marker trigger first" '[ -n "$(marker_file "$PU_SID")" ] && [ "$(json_get "$(marker_file "$PU_SID")" trigger)" = first ]'
  pu_check "first PostToolUse did not re-run the command" 'pu_not_ran'
  # --- marker present: PostToolUse and Exit code 1 exit at once, file untouched.
  snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "marker present: PostToolUse prints nothing, file unchanged" '[ -n "$(marker_file "$PU_SID")" ] && [ "$PU_RC" -eq 0 ] && [ ! -s "$PU_OUT" ] && [ "$(snap_value "$F")" = "$PU_WIN" ]'
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 1\nboom'
  pu_check "marker present: Exit code 1 prints nothing, file unchanged" '[ -n "$(marker_file "$PU_SID")" ] && [ "$PU_RC" -eq 0 ] && [ ! -s "$PU_OUT" ] && [ "$(snap_value "$F")" = "$PU_WIN" ]'
  # --- recheck on Exit code 127: repaired, marker -> recheck, confirmed sentence.
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nfoo: command not found'
  pu_check "recheck repairs the re-broken snapshot" 'snap_is_ok "$F"'
  pu_check "recheck marker trigger recheck" '[ "$(json_get "$(marker_file "$PU_SID")" trigger)" = recheck ]'
  pu_check "recheck confirmed sentence" 'pu_has "$SNAP_CONFIRMED_SENTENCE"'
  pu_check "recheck did not re-run the command" 'pu_not_ran'

  # --- first (PostToolUseFailure, Exit code 127): confirmed sentence.
  pu_home; F="$PU_D/$(pu_name -30000 b)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nfoo: command not found'
  pu_check "first Exit code 127 repairs" 'snap_is_ok "$F"'
  pu_check "first Exit code 127 hookEventName" '[ "$(json_get "$PU_OUT" hookSpecificOutput.hookEventName)" = PostToolUseFailure ]'
  pu_check "first Exit code 127 confirmed sentence" 'pu_has "$SNAP_CONFIRMED_SENTENCE"'
  pu_check "first Exit code 127 did not re-run the command" 'pu_not_ran'

  # --- first (PostToolUseFailure, Exit code 1): neutral wording.
  pu_home; F="$PU_D/$(pu_name -30000 c)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 1\nboom'
  pu_check "first Exit code 1 repairs with neutral wording" 'snap_is_ok "$F" && pu_neutral_ok'
  pu_check "first Exit code 1 did not re-run the command" 'pu_not_ran'

  # pu_marked_home — fresh home whose marker already exists (an empty-dir first run), so the
  # next Exit code 127 is a recheck; sets PU_MARK and PU_MARK_BEFORE.
  pu_marked_home() {
    pu_home
    pu_run "$PU_H" PostToolUse "$PU_SID"
    PU_MARK="$(marker_file "$PU_SID")"
    PU_MARK_BEFORE="$(cat "$PU_MARK" 2>/dev/null)"
  }
  # pu_range_fixture — oldest windows-form (this session) + 4 newer healthy (other sessions).
  pu_range_fixture() {
    F="$PU_D/$(pu_name -50000 old)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
    for _i in 1 2 3 4; do snap_write "$PU_D" "$(pu_name $((-50000 + _i * 5000)) ok$_i)" '/mingw64/bin:/usr/bin:/bin'; done
  }
  # pu_count_ok — number of snapshots in PU_D whose PATH reaches /usr/bin or /bin.
  pu_count_ok() { local f c=0; for f in "$PU_D"/*.sh; do snap_is_ok "$f" && c=$((c + 1)); done; echo "$c"; }

  # --- range: both triggers judge every snapshot since the lower bound, not the newest only.
  pu_home; pu_range_fixture
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "range first: old windows-form behind 4 newer healthy is repaired" '[ "$PU_RC" -eq 0 ] && snap_is_ok "$F"'
  pu_marked_home; pu_range_fixture
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
  pu_check "range recheck: old windows-form behind 4 newer healthy is repaired" '[ "$PU_RC" -eq 0 ] && snap_is_ok "$F"'

  # --- first repairs several: 2 windows-form (this session + another) both fixed, marker first.
  pu_home
  F="$PU_D/$(pu_name -40000 two-a)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  F2="$PU_D/$(pu_name -20000 two-b)"; snap_write "$PU_D" "${F2##*/}" "$PU_WIN"
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "first repairs both windows-form snapshots" 'snap_is_ok "$F" && snap_is_ok "$F2"'
  pu_check "first with two repairs writes marker trigger first" '[ -n "$(marker_file "$PU_SID")" ] && [ "$(json_get "$(marker_file "$PU_SID")" trigger)" = first ]'

  # --- first repair cap: 6 broken -> 5 newest repaired, 1 deferred, no marker; then the last one.
  pu_home
  for _i in 0 1 2 3 4 5; do snap_write "$PU_D" "$(pu_name $((-50000 + _i * 1000)) fcap$_i)" "$PU_WIN"; done
  PU_OLDEST="$PU_D/$(pu_name -50000 fcap0)"
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "first cap: oldest left, five newer repaired" '[ "$(snap_value "$PU_OLDEST")" = "$PU_WIN" ] && [ "$(pu_count_ok)" -eq 5 ]'
  pu_check "first cap: notice names deferred max-repairs" 'pu_has max-repairs'
  pu_check "first cap: marker not written while deferred" '[ "$PU_RC" -eq 0 ] && pu_has max-repairs && [ -z "$(marker_file "$PU_SID")" ]'
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "first cap: next call repairs the last one and writes marker first" 'snap_is_ok "$PU_OLDEST" && [ "$(json_get "$(marker_file "$PU_SID")" trigger)" = first ]'

  # --- recheck repair cap: 6 broken -> 5 newest repaired, 1 deferred, marker kept; then the last one.
  pu_marked_home
  for _i in 0 1 2 3 4 5; do snap_write "$PU_D" "$(pu_name $((-50000 + _i * 1000)) cap$_i)" "$PU_WIN"; done
  PU_OLDEST="$PU_D/$(pu_name -50000 cap0)"
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
  pu_check "recheck cap: oldest left, five newer repaired" '[ "$(snap_value "$PU_OLDEST")" = "$PU_WIN" ] && [ "$(pu_count_ok)" -eq 5 ]'
  pu_check "recheck cap: notice names deferred max-repairs" 'pu_has max-repairs'
  pu_check "recheck cap: marker not updated while deferred" '[ -n "$PU_MARK" ] && [ "$(cat "$PU_MARK")" = "$PU_MARK_BEFORE" ]'
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
  pu_check "recheck cap: next exit 127 repairs the last one and updates the marker" 'snap_is_ok "$PU_OLDEST" && [ "$(json_get "$(marker_file "$PU_SID")" trigger)" = recheck ]'

  # --- parallel runs on the same snapshot: one ok content, no tmp, both rc 0 with valid output.
  pu_home; F="$PU_D/$(pu_name -30000 par)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  pu_input "$SNAP_TMP/par1.in" PostToolUse par-sid-1 "$PU_TR"
  pu_input "$SNAP_TMP/par2.in" PostToolUse par-sid-2 "$PU_TR"
  ( HOME="$PU_H" USERPROFILE="$PU_H" run_with_timeout 30 node "$POSTUSE_HOOK" < "$SNAP_TMP/par1.in" > "$SNAP_TMP/par1.out" 2>/dev/null; echo $? > "$SNAP_TMP/par1.rc" ) &
  ( HOME="$PU_H" USERPROFILE="$PU_H" run_with_timeout 30 node "$POSTUSE_HOOK" < "$SNAP_TMP/par2.in" > "$SNAP_TMP/par2.out" 2>/dev/null; echo $? > "$SNAP_TMP/par2.rc" ) &
  wait
  pu_check "parallel: final file ok, no tmp left" 'snap_is_ok "$F" && [ -z "$(find "$PU_D" -name "*.repair.tmp")" ]'
  for _p in 1 2; do
    pu_check "parallel: run $_p rc 0 and empty-or-JSON output" '[ "$(cat "$SNAP_TMP/par$_p.rc")" = 0 ] && [ "$(json_get "$SNAP_TMP/par$_p.out" "")" != __INVALID__ ]'
  done

  # --- replace failure: read-only snapshot -> write-failed notice, rc 0, file unchanged.
  pu_home; F="$PU_D/$(pu_name -30000 ro)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  node -e "require('fs').chmodSync(process.argv[1], 0o444)" "$(np "$F")"
  pu_run "$PU_H" PostToolUse "$PU_SID"
  node -e "require('fs').chmodSync(process.argv[1], 0o644)" "$(np "$F")"
  pu_check "read-only snapshot: write-failed notice, rc 0, unchanged" '[ "$PU_RC" -eq 0 ] && pu_has write-failed && [ "$(snap_value "$F")" = "$PU_WIN" ]'

  # --- no transcript: only the last 15 minutes count.
  pu_home; F="$PU_D/$(pu_name -60000 recent)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
  PU_TR="$(np "$PU_H/no-such-transcript.jsonl")"
  pu_run "$PU_H" PostToolUse "$PU_SID"
  pu_check "no transcript: a 1-minute-old snapshot is repaired" 'snap_is_ok "$F"'
else
  skip "postuse: repair paths need the real cygpath (win32 Git Bash) — covered by repair-file-cas/scan-and-repair stubs"
fi

# --- no transcript: a 20-minute-old snapshot is outside the 15-minute window.
pu_home; F="$PU_D/$(pu_name -1200000 stale)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
PU_TR="$(np "$PU_H/no-such-transcript.jsonl")"
pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
pu_check "no transcript: a 20-minute-old snapshot is left alone, rc 0" '[ "$PU_RC" -eq 0 ] && [ "$(snap_value "$F")" = "$PU_WIN" ] && [ -n "$(marker_file "$PU_SID")" ]'

# --- other sessions' snapshots (created before the lower bound) are never touched.
pu_home; SNAP_OTHER_HOME="$PU_H"; SNAP_OTHER_TR="$PU_TR"
SNAP_OTHER_FILE="$PU_D/$(pu_name -600000 other)"; snap_write "$PU_D" "${SNAP_OTHER_FILE##*/}" "$PU_WIN"
SNAP_OTHER_FOO="$PU_D/foo-other.sh"; snap_write "$PU_D" foo-other.sh "$PU_WIN"; set_mtime_ms "$SNAP_OTHER_FOO" $((PU_NOW - 600000))
pu_run "$PU_H" PostToolUse "$PU_SID"
pu_check "other session: first leaves pre-bound snapshots alone" '[ "$(snap_value "$SNAP_OTHER_FILE")" = "$PU_WIN" ] && [ "$(snap_value "$SNAP_OTHER_FOO")" = "$PU_WIN" ] && [ -n "$(marker_file "$PU_SID")" ]'
pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
pu_check "other session: recheck leaves pre-bound snapshots alone" '[ "$(snap_value "$SNAP_OTHER_FILE")" = "$PU_WIN" ] && [ "$(snap_value "$SNAP_OTHER_FOO")" = "$PU_WIN" ] && [ "$PU_RC" -eq 0 ]'

# --- unrepairable: warned once, bytes unchanged, file kept; duplicate notice suppressed.
pu_home; F="$PU_D/$(pu_name -30000 unrep)"; snap_write "$PU_D" "${F##*/}" 'C:\a;relative\dir'
cp "$F" "$SNAP_TMP/unrep.orig"
pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
pu_check "unrepairable: warning says not rewritten" 'pu_has "not rewritten" && pu_has windows-unrepairable'
pu_check "unrepairable: bytes unchanged, file kept" 'cmp -s "$F" "$SNAP_TMP/unrep.orig"'
pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
pu_check "unrepairable: second exit 127 does not repeat the notice" '[ "$PU_RC" -eq 0 ] && ! pu_has windows-unrepairable && cmp -s "$F" "$SNAP_TMP/unrep.orig"'
pu_check "unrepairable: second exit 127 output is empty or valid JSON" '[ "$PU_RC" -eq 0 ] && [ "$(json_get "$PU_OUT" "")" != __INVALID__ ]'

# --- no cygpath (every host): Exit code 127 first -> cygpath-unavailable notice, bytes unchanged.
# The notice has no platform branch for this reason, so the same wording is pinned everywhere.
pu_home; F="$PU_D/$(pu_name -30000 nocyg)"; snap_write "$PU_D" "${F##*/}" "$PU_WIN"
cp "$F" "$SNAP_TMP/pu-nocyg.orig"
PU_N=$((PU_N + 1)); PU_OUT="$SNAP_TMP/pu-out-$PU_N"
pu_input "$PU_OUT.in" PostToolUseFailure "$PU_SID" "$PU_TR" 'Exit code 127\nfoo: command not found'
run_no_cygpath "$PU_H" "$POSTUSE_HOOK" < "$PU_OUT.in" > "$PU_OUT" 2> "$PU_OUT.err"
PU_RC=$?
pu_check "no cygpath: rc 0, snapshot bytes unchanged" '[ "$PU_RC" -eq 0 ] && cmp -s "$F" "$SNAP_TMP/pu-nocyg.orig"'
pu_check "no cygpath: notice names cygpath-unavailable and the file" 'pu_has "not rewritten (windows-form, cygpath-unavailable)" && pu_has "${F##*/}"'
pu_check "no cygpath: no repaired or confirmed sentence" '! pu_has "PATH has been repaired" && ! pu_has "$SNAP_CONFIRMED_SENTENCE"'
pu_check "no cygpath: did not re-run the command" 'pu_not_ran'

# --- fail-open: non-JSON input, no snapshot dir, unwritable state dir -> exit 0.
pu_home
printf 'not json' > "$SNAP_TMP/bad.in"
HOME="$PU_H" USERPROFILE="$PU_H" run_with_timeout 30 node "$POSTUSE_HOOK" < "$SNAP_TMP/bad.in" > /dev/null 2>&1
PU_RC=$?; pu_check "fail-open: non-JSON input exits 0" '[ "$PU_RC" -eq 0 ] && [ -f "$POSTUSE_HOOK" ]'
rm -rf "$PU_H/.claude"
pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
pu_check "fail-open: no snapshot dir exits 0" '[ "$PU_RC" -eq 0 ] && [ -f "$POSTUSE_HOOK" ]'
pu_home; snap_write "$PU_D" "$(pu_name -30000 st)" "$PU_WIN"
printf 'file' > "$SNAP_TMP/state-is-a-file"
(
  export WORKFLOW_STATE_DIR="$SNAP_TMP/state-is-a-file"
  pu_run "$PU_H" PostToolUseFailure "$PU_SID" 'Exit code 127\nx'
  echo "$PU_RC" > "$SNAP_TMP/state-unwritable.rc"
)
PU_RC="$(cat "$SNAP_TMP/state-unwritable.rc")"
pu_check "fail-open: unwritable state dir exits 0" '[ "$PU_RC" -eq 0 ] && [ -f "$POSTUSE_HOOK" ]'
