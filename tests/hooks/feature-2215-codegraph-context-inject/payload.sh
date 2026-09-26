# shellcheck shell=bash
# Tests: hooks/codegraph-context-inject.js, hooks/lib/codegraph-boundary.js, hooks/lib/path-normalize.js
# Tags: hook-injection, codegraph, prompt-hook, side-effect-absence, TL2, scope:issue-specific
# M22-M24 — what crosses into the child: payload bytes, the SSOT telemetry env pair, the ~/.codegraph guard.

# ===========================================================================
# M22: child stdin is byte-identical when cwd needs no normalization
# ===========================================================================
# $ORD_PLAIN is cygpath's "C:/..." mixed form, which normalizeCwd() rewrites to "C:\..."
# on win32, so the payload must already be platform-canonical or byte-identity could
# never hold. $BS2 is four backslashes: ${var//pat/repl} eats one level in the replacement.
if [ "$IS_WIN32" -eq 1 ]; then
    BS2='\\\\'
    ORD_PLAIN_CANON="${ORD_PLAIN//\//$BS2}"
else
    ORD_PLAIN_CANON="$ORD_PLAIN"
fi
PAYLOAD22="{\"prompt\":\"hi there\",\"cwd\":\"$ORD_PLAIN_CANON\",\"session_id\":\"s-22\",\"hook_event_name\":\"UserPromptSubmit\"}"
RESET_LOGS
run_hook "$PAYLOAD22" "$ORD_PLAIN" >/dev/null
child_stdin22="$([ -f "$STDIN_LOG" ] && cat "$STDIN_LOG" || echo "__MISSING__")"
if [ "$child_stdin22" = "$PAYLOAD22" ]; then
    pass "M22: child stdin byte-identical to raw payload (no normalization needed)"
else
    fail "M22: child stdin='$child_stdin22' expected='$PAYLOAD22'"
fi

# ===========================================================================
# M22b: POSIX drive-form cwd -> child's cwd is normalized, other keys intact
# ===========================================================================
if [ "$IS_WIN32" -eq 1 ]; then
    POSIX_CWD="/c/git/agents-2215-fixture"
    PAYLOAD22b="{\"prompt\":\"p22b\",\"cwd\":\"$POSIX_CWD\",\"session_id\":\"s-22b\",\"hook_event_name\":\"UserPromptSubmit\"}"
    RESET_LOGS
    run_hook "$PAYLOAD22b" "$ORD_PLAIN" >/dev/null
    child_stdin22b="$([ -f "$STDIN_LOG" ] && cat "$STDIN_LOG" || echo "")"
    got_cwd=$(json_field "$child_stdin22b" "cwd")
    got_prompt=$(json_field "$child_stdin22b" "prompt")
    got_sid=$(json_field "$child_stdin22b" "session_id")
    got_evt=$(json_field "$child_stdin22b" "hook_event_name")
    if [ "$got_cwd" = "C:\\git\\agents-2215-fixture" ] && [ "$got_prompt" = "p22b" ] && [ "$got_sid" = "s-22b" ] && [ "$got_evt" = "UserPromptSubmit" ]; then
        pass "M22b (forwarded): POSIX drive-form cwd normalized in child stdin; other keys intact"
    else
        fail "M22b (forwarded): cwd='$got_cwd' prompt='$got_prompt' sid='$got_sid' evt='$got_evt' raw='$child_stdin22b'"
    fi
else
    PAYLOAD22b="{\"prompt\":\"p22b\",\"cwd\":\"/c/git/agents-2215-fixture\",\"session_id\":\"s-22b\",\"hook_event_name\":\"UserPromptSubmit\"}"
    RESET_LOGS
    run_hook "$PAYLOAD22b" "$ORD_PLAIN" >/dev/null
    child_stdin22b="$([ -f "$STDIN_LOG" ] && cat "$STDIN_LOG" || echo "")"
    if [ "$child_stdin22b" = "$PAYLOAD22b" ]; then
        pass "M22b (forwarded, non-win32): normalizeCwd is a no-op, raw passthrough"
    else
        fail "M22b (forwarded, non-win32): child stdin='$child_stdin22b'"
    fi
fi

# M22b unit case: normalizePayloadCwd() called directly with process.platform
# forced to 'win32', independent of the host OS.
unit22b=$(node -e "
try {
  Object.defineProperty(process, 'platform', { value: 'win32' });
  const boundary = require(process.argv[1]);
  process.stdout.write(String(boundary.normalizePayloadCwd('/c/git/agents')));
} catch (e) { process.stdout.write('__ERROR__:' + e.message); }
" "$BOUNDARY" 2>/dev/null)
if [ "$unit22b" = "C:\\git\\agents" ]; then
    pass "M22b (unit): normalizePayloadCwd('/c/git/agents') under forced win32 -> 'C:\\git\\agents'"
else
    fail "M22b (unit): got '$unit22b'"
fi

# ===========================================================================
# M23: child env carries the FULL SSOT telemetry pair (CODEGRAPH_TELEMETRY AND
# DO_NOT_TRACK -- #2215's SSOT contract governs both env vars together, not
# CODEGRAPH_TELEMETRY alone)
# ===========================================================================
EXPECTED_TELEMETRY=$(grep '^CODEGRAPH_TELEMETRY=' "$CONSTANTS_FILE" 2>/dev/null | head -1 | cut -d= -f2)
EXPECTED_DNT=$(grep '^DO_NOT_TRACK=' "$CONSTANTS_FILE" 2>/dev/null | head -1 | cut -d= -f2)
RESET_LOGS
run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" >/dev/null
child_env23="$([ -f "$ENV_LOG" ] && cat "$ENV_LOG" || echo "__MISSING__")"
if [ -n "$EXPECTED_TELEMETRY" ] && [ -n "$EXPECTED_DNT" ] && [ "$child_env23" = "CODEGRAPH_TELEMETRY=$EXPECTED_TELEMETRY DO_NOT_TRACK=$EXPECTED_DNT" ]; then
    pass "M23: child env carries both CODEGRAPH_TELEMETRY and DO_NOT_TRACK at the SSOT values (install/codegraph-constants.txt): $EXPECTED_TELEMETRY / $EXPECTED_DNT"
else
    fail "M23: expected 'CODEGRAPH_TELEMETRY=$EXPECTED_TELEMETRY DO_NOT_TRACK=$EXPECTED_DNT' (both non-empty), got '$child_env23'"
fi

# ===========================================================================
# M24: negative guard -- $FAKE_HOME/.codegraph is untouched by hook execution
# ===========================================================================
# Seed telemetry.json BEFORE running: an unseeded dir never exists, so a hook
# that wrongly reuses the installer's delete-based reset (S5-5/S5-6) would
# find nothing to delete and this guard would pass vacuously. Content is
# compared byte-for-byte (not just presence) so a rewrite is caught too.
mkdir -p "$FAKE_HOME/.codegraph"
printf '{"enabled":false,"machine_id":"m-2215-m24","consent_source":"cli","first_run_notice_shown":true,"updated_at":"2026-01-01T00:00:00.000Z"}\n' > "$FAKE_HOME/.codegraph/telemetry.json"
find "$FAKE_HOME/.codegraph" 2>/dev/null | sort > "$TMPDIR_BASE/before-24.txt" || : > "$TMPDIR_BASE/before-24.txt"
digest_before24=$(node -e "try{process.stdout.write(require('fs').readFileSync(process.argv[1],'utf8'))}catch(e){process.stdout.write('__MISSING__')}" "$FAKE_HOME/.codegraph/telemetry.json")
RESET_LOGS
run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" >/dev/null
find "$FAKE_HOME/.codegraph" 2>/dev/null | sort > "$TMPDIR_BASE/after-24.txt" || : > "$TMPDIR_BASE/after-24.txt"
digest_after24=$(node -e "try{process.stdout.write(require('fs').readFileSync(process.argv[1],'utf8'))}catch(e){process.stdout.write('__MISSING__')}" "$FAKE_HOME/.codegraph/telemetry.json")
if diff -q "$TMPDIR_BASE/before-24.txt" "$TMPDIR_BASE/after-24.txt" >/dev/null 2>&1 && [ "$digest_before24" = "$digest_after24" ]; then
    pass "M24: \$FAKE_HOME/.codegraph unchanged by hook execution (listing and telemetry.json content both identical; reset stays installer-only)"
else
    fail "M24: \$FAKE_HOME/.codegraph changed after hook execution (listing diff and/or telemetry.json content differs)"
fi
# Restore $FAKE_HOME for later cases (M27/M27b/M31 also use it as HOME).
rm -rf "$FAKE_HOME/.codegraph"
