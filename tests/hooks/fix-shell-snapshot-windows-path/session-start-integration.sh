#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/session-start-integration.sh
# Tests: hooks/session-start.js
# Tags: hook, shell-snapshot, session-start, integration, scope:issue-specific, TL2
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher).
# The real session-start.js over a fixture home: neutral repair, unrepairable warned not deleted, fail-open,
# recovery of the pre-bound snapshot postuse-integration.sh left (SNAP_OTHER_HOME / SNAP_OTHER_FILE).
# TL3 gap (what this test does NOT catch):
# - Real CC firing SessionStart (startup / compact) through the settings.json registration.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

SS_N=0
SS_WIN='C:\Windows\System32;C:\Windows'

# ss_run <home> <source> [transcript] — sets SS_OUT (file) and SS_RC; SS_LINES = snapshot lines.
ss_run() {
  SS_N=$((SS_N + 1))
  SS_OUT="$SNAP_TMP/ss-out-$SS_N"
  printf '{"session_id":"ss-sid-%s","source":"%s","transcript_path":"%s"}' "$SS_N" "$2" "${3:-}" > "$SS_OUT.in"
  HOME="$1" USERPROFILE="$1" run_with_timeout 30 node "$SESSION_START_HOOK" < "$SS_OUT.in" > "$SS_OUT" 2> "$SS_OUT.err"
  SS_RC=$?
  SS_CTX="$(json_get "$SS_OUT" additionalContext)"
  SS_LINES="$(printf '%s\n' "$SS_CTX" | grep -iE 'snapshot|PATH has been repaired' || true)"
}
ss_home() { SS_N=$((SS_N + 1)); SS_H="$SNAP_TMP/ss-home-$SS_N"; SS_D="$SS_H/.claude/shell-snapshots"; mkdir -p "$SS_D"; }
ss_name() { printf 'snapshot-bash-%s-%s.sh' "$(( $(now_ms) - $1 ))" "$2"; }
ss_check() { if eval "$2"; then pass "session-start: $1"; else fail "session-start: $1" "rc=$SS_RC lines=${SS_LINES:0:300}"; fi; }
ss_neutral() {
  case "$SS_LINES" in *"exited with code 127"*|*"exiting 127"*|*"previous command"*|*"re-run"*) return 1 ;; esac
  case "$SS_LINES" in *"PATH has been repaired"*) return 0 ;; esac
  return 1
}

if have_cygpath_host; then
  for _src in startup compact; do
    ss_home; F="$SS_D/$(ss_name 60000 wf)"; snap_write "$SS_D" "${F##*/}" "$SS_WIN"
    ss_run "$SS_H" "$_src"
    ss_check "windows-form ($_src) repaired with a neutral WARNING" '[ "$SS_RC" -eq 0 ] && snap_is_ok "$F" && ss_neutral && printf "%s" "$SS_LINES" | grep -q WARNING'
    if [ "$_src" = compact ]; then
      ss_check "compact + broken newest adds the likely-this-session line" 'printf "%s" "$SS_LINES" | grep -qi "likely this session"'
    else
      ss_check "startup never adds the likely-this-session line" '[ -n "$SS_LINES" ] && ! printf "%s" "$SS_LINES" | grep -qi "likely this session"'
    fi
  done
  # Recovery of what the PostToolUse path skipped (pre-bound snapshot from postuse-integration).
  if [ -n "${SNAP_OTHER_HOME:-}" ] && [ -f "${SNAP_OTHER_FILE:-}" ]; then
    ss_run "$SNAP_OTHER_HOME" compact "$SNAP_OTHER_TR"
    ss_check "compact recovers the snapshot the PostToolUse path left alone" 'snap_is_ok "$SNAP_OTHER_FILE"'
  else
    fail "session-start: pre-bound fixture from postuse-integration is missing"
  fi
else
  skip "session-start: repair paths need the real cygpath (win32 Git Bash)"
fi

# Unrepairable (";" shape and the colon-trace shape): unchanged, kept, warned with count 2.
ss_home
U1="$SS_D/$(ss_name 120000 u1)"; snap_write "$SS_D" "${U1##*/}" 'C:\a;relative\dir'
U2="$SS_D/$(ss_name 110000 u2)"; snap_write "$SS_D" "${U2##*/}" 'C:\repo\dotfiles/bin:/c/x'
cp "$U1" "$SNAP_TMP/ss-u1.orig"; cp "$U2" "$SNAP_TMP/ss-u2.orig"
ss_run "$SS_H" startup
ss_check "unrepairable: both files byte-identical and kept" 'cmp -s "$U1" "$SNAP_TMP/ss-u1.orig" && cmp -s "$U2" "$SNAP_TMP/ss-u2.orig"'
ss_check "unrepairable: WARNING with count 2 and the reason" 'printf "%s" "$SS_LINES" | grep -q WARNING && printf "%s" "$SS_LINES" | grep -q windows-unrepairable && printf "%s" "$SS_LINES" | grep -qiE "(^|[^0-9])2 snapshot"'
ss_check "unrepairable: restart and dry-run advice, no deletion promise" 'printf "%s" "$SS_LINES" | grep -qi restart && printf "%s" "$SS_LINES" | grep -qF "/sweep-shell-snapshots --dry-run" && ! printf "%s" "$SS_LINES" | grep -qiE "will be deleted|will delete"'

# No cygpath (every host): startup warns cygpath-unavailable, bytes unchanged, nothing repaired.
ss_home; F="$SS_D/$(ss_name 60000 nocyg)"; snap_write "$SS_D" "${F##*/}" "$SS_WIN"
cp "$F" "$SNAP_TMP/ss-nocyg.orig"
SS_N=$((SS_N + 1)); SS_OUT="$SNAP_TMP/ss-out-$SS_N"
printf '{"session_id":"ss-sid-%s","source":"startup","transcript_path":""}' "$SS_N" > "$SS_OUT.in"
run_no_cygpath "$SS_H" "$SESSION_START_HOOK" < "$SS_OUT.in" > "$SS_OUT" 2> "$SS_OUT.err"
SS_RC=$?
SS_CTX="$(json_get "$SS_OUT" additionalContext)"
SS_LINES="$(printf '%s\n' "$SS_CTX" | grep -iE 'snapshot|PATH has been repaired' || true)"
ss_check "no cygpath: rc 0, snapshot bytes unchanged" '[ "$SS_RC" -eq 0 ] && cmp -s "$F" "$SNAP_TMP/ss-nocyg.orig"'
ss_check "no cygpath: WARNING names cygpath-unavailable and the file" 'printf "%s" "$SS_LINES" | grep -q "WARNING (shell snapshot): 1 snapshot(s) not rewritten (windows-form, cygpath-unavailable)" && printf "%s" "$SS_LINES" | grep -qF "${F##*/}"'
ss_check "no cygpath: no repaired or confirmed sentence" '! printf "%s" "$SS_LINES" | grep -qF "PATH has been repaired" && ! printf "%s" "$SS_LINES" | grep -qF "exited with code 127"'

# Healthy only (including the real-world shape with C:\repo\dotfiles/bin mid-PATH): silent.
ss_home
H1="$SS_D/$(ss_name 60000 h1)"; snap_write "$SS_D" "${H1##*/}" '/c/WINDOWS/System32/OpenSSH:/mingw64/bin:/usr/bin:/bin:C:\repo\dotfiles/bin:/x'
H2="$SS_D/$(ss_name 50000 h2)"; snap_write "$SS_D" "${H2##*/}" '/usr/bin:/bin'
cp "$H1" "$SNAP_TMP/ss-h1.orig"
ss_run "$SS_H" startup
ss_check "healthy only: no snapshot WARNING, file unchanged" '[ "$SS_RC" -eq 0 ] && [ -z "$SS_LINES" ] && cmp -s "$H1" "$SNAP_TMP/ss-h1.orig"'

# The repair lib throwing: still valid JSON and exit 0. The preload proves the lib was reached.
cat > "$SNAP_TMP/throwing-lib.js" <<'JS'
const M = require('module');
const fs = require('fs');
const orig = M._load;
M._load = function (req, parent, isMain) {
  if (/(^|[\/\\])shell-snapshot-repair(\.js)?$/.test(String(req))) {
    try { fs.writeFileSync(process.env.SNAP_INTERCEPT, '1'); } catch (e) { /* ignore */ }
    return new Proxy({}, { get() { return () => { throw new Error('injected failure'); }; } });
  }
  return orig.apply(this, arguments);
};
JS
ss_home; snap_write "$SS_D" "$(ss_name 60000 thr)" "$SS_WIN"
SNAP_INTERCEPT="$(np "$SNAP_TMP/intercepted")"
printf '{"session_id":"ss-throw","source":"startup"}' > "$SNAP_TMP/ss-throw.in"
SNAP_INTERCEPT="$SNAP_INTERCEPT" NODE_OPTIONS="--require $(np "$SNAP_TMP/throwing-lib.js")" HOME="$SS_H" USERPROFILE="$SS_H" \
  run_with_timeout 30 node "$SESSION_START_HOOK" < "$SNAP_TMP/ss-throw.in" > "$SNAP_TMP/ss-throw.out" 2>/dev/null
SS_RC=$?
SS_LINES=""
ss_check "lib throws: valid JSON, exit 0" '[ "$SS_RC" -eq 0 ] && [ "$(json_get "$SNAP_TMP/ss-throw.out" "")" != __INVALID__ ] && [ "$(json_get "$SNAP_TMP/ss-throw.out" "")" != __EMPTY__ ]'
ss_check "lib throws: the repair lib was actually reached" '[ -f "$SNAP_TMP/intercepted" ]'
