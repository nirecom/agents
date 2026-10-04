#!/usr/bin/env bash
# tests/hooks/legacy-session-id-relay-purge.sh
# Tests: hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js, hooks/session-start.js
# Tags: TL2, scope:issue-specific, pwsh-not-required, session-id
# Issue #1091: session-start.js no longer relays CLAUDE_SESSION_ID into CLAUDE_ENV_FILE;
# the temporary migration purges relay lines that earlier versions left behind.
# This file is TOMBSTONE_EXEMPT in bin/check-session-id-ssot.sh, so it may name the
# retired variables. RED until the purge module exists and the relay write is removed.
# TL3 gap: a real CC-owned env file across a live SessionStart; see
# tests/hooks/TL3-hook-session-id-entrypoint-coverage.sh.

set -euo pipefail

# Pin to this checkout: an inherited AGENTS_DIR would point the harness at another tree.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$(dirname "$0")/../lib/harness.sh"

MODULE_NODE="$(np "$AGENTS_DIR/hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js")"
SESSION_START_NODE="$(np "$AGENTS_DIR/hooks/session-start.js")"

TMP_BASE="$(make_tmp)"
trap 'chmod -R u+w "$TMP_BASE" 2>/dev/null || true; rm -rf "$TMP_BASE"' EXIT
harness_isolate "$TMP_BASE"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_BASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
FIXTURE_REPO="$TMP_BASE/repo"
harness_git_init "$FIXTURE_REPO"

# purge <path|__UNSET__> — prints the JSON result, or ERR when the module throws/is missing.
purge() {
  (cd "$TMP_BASE" && run_with_timeout 10 env -u CLAUDE_ENV_FILE node -e '
const m = require(process.argv[1]);
const a = process.argv[2];
const r = a === "__UNSET__" ? m.purgeLegacyRelayLines() : m.purgeLegacyRelayLines(a);
process.stdout.write(JSON.stringify(r));
' -- "$MODULE_NODE" "$1" 2>/dev/null) || echo "ERR"
}

json_field() {
  node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write(String(o[process.argv[2]]));}catch(_){process.stdout.write("PARSE_ERR");}' -- "$1" "$2"
}

mtime_of() {
  node -e 'process.stdout.write(String(require("fs").statSync(process.argv[1]).mtimeMs))' -- "$(np "$1")"
}

# Push mtime 100s into the past so any rewrite is observable as an mtime change.
age_file() {
  node -e 'const t=Date.now()/1000-100;require("fs").utimesSync(process.argv[1],t,t)' -- "$(np "$1")"
}

# run_hook <env-file|__UNSET__> <stdin-json> — sets HOOK_RC / HOOK_OUT.
HOOK_RC=0
HOOK_OUT=""
run_hook() {
  local env_file="$1" input="$2"
  if [ "$env_file" = "__UNSET__" ]; then
    HOOK_OUT="$(cd "$FIXTURE_REPO" && printf '%s' "$input" | CLAUDE_PROJECT_DIR="$(np "$FIXTURE_REPO")" \
      run_with_timeout 30 env -u CLAUDE_ENV_FILE node "$SESSION_START_NODE" 2>/dev/null)" \
      && HOOK_RC=0 || HOOK_RC=$?
  else
    HOOK_OUT="$(cd "$FIXTURE_REPO" && printf '%s' "$input" | CLAUDE_ENV_FILE="$(np "$env_file")" \
      CLAUDE_PROJECT_DIR="$(np "$FIXTURE_REPO")" run_with_timeout 30 node "$SESSION_START_NODE" 2>/dev/null)" \
      && HOOK_RC=0 || HOOK_RC=$?
  fi
}

hook_out_is_json() {
  printf '%s' "$HOOK_OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{JSON.parse(s);process.exit(0)}catch(_){process.exit(1)}})'
}

HOOK_INPUT='{"session_id":"test-sid","hook_event_name":"SessionStart"}'

# ---------------------------------------------------------------------------
case_begin "P1 50 relay lines purged, unrelated line kept" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p1.env"
: > "$f"
for _ in $(seq 1 50); do printf 'CLAUDE_SESSION_ID=aaa\n' >> "$f"; done
printf 'export FOO=1\n' >> "$f"
out="$(purge "$(np "$f")")"
if [ "$(cat "$f")" = "export FOO=1" ] && [ "$(json_field "$out" changed)" = "true" ] && [ "$(json_field "$out" removed)" = "50" ]; then
  pass "P1: 50 relay lines removed, export FOO=1 kept (result=$out)"
else
  fail "P1: 50 relay lines removed" "result=$out content=$(head -c 200 "$f" | tr '\n' '|')"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P2 every relay value purged regardless of value" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p2.env"
printf 'CLAUDE_SESSION_ID=old\nKEEP=1\nCLAUDE_SESSION_ID=20661003-current-sid\nCLAUDE_SESSION_ID=\n' > "$f"
out="$(purge "$(np "$f")")"
if [ "$(cat "$f")" = "KEEP=1" ]; then
  pass "P2: old, current and empty-valued relay lines all removed"
else
  fail "P2: relay lines removed regardless of value" "result=$out content=$(tr '\n' '|' < "$f")"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P3 look-alike names untouched" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p3.env"
printf 'CLAUDE_CODE_SESSION_ID=x\nexport CLAUDE_SESSION_ID=y\nMY_CLAUDE_SESSION_ID=z\nCLAUDE_SESSION_ID_EXTRA=w\n' > "$f"
cp "$f" "$f.orig"
age_file "$f"
before="$(mtime_of "$f")"
out="$(purge "$(np "$f")")"
after="$(mtime_of "$f")"
if cmp -s "$f" "$f.orig" && [ "$before" = "$after" ] && [ "$(json_field "$out" changed)" = "false" ]; then
  pass "P3: look-alike names left byte-identical, mtime unchanged"
else
  fail "P3: look-alike names untouched" "result=$out mtime $before->$after content=$(tr '\n' '|' < "$f")"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P4 CRLF relay lines removed, other line endings preserved" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p4.env"
printf 'A=1\nCLAUDE_SESSION_ID=x\r\nB=2\r\nCLAUDE_SESSION_ID=y\r\nC=3\n' > "$f"
printf 'A=1\nB=2\r\nC=3\n' > "$f.want"
out="$(purge "$(np "$f")")"
if cmp -s "$f" "$f.want"; then
  pass "P4: CRLF relay lines removed; LF and CRLF of kept lines preserved"
else
  fail "P4: CRLF handling" "result=$out bytes=$(od -c "$f" | head -3 | tr '\n' ' ')"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "Rx RELAY_LINE_RE boundary: match/no-match (table-driven)" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"

assert_relay_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "Rx/$name"
  else fail "Rx/$name" "want=$want got=$got"; fi
}

eval_relay_match() {
  local f="$TMP_BASE/rx-test.env"
  printf '%s\n' "$1" > "$f"
  local r
  r="$(purge "$(np "$f")")"
  if [ "$(json_field "$r" removed)" = "1" ]; then echo "match"; else echo "no-match"; fi
}

while IFS='|' read -r _rx_name _rx_input _rx_want; do
  [[ -z "$_rx_name" || "$_rx_name" =~ ^[[:space:]]*# ]] && continue
  _rx_name="${_rx_name//[[:space:]]/}"
  _rx_want="${_rx_want//[[:space:]]/}"
  _rx_input="${_rx_input#"${_rx_input%%[! ]*}"}"
  _rx_input="${_rx_input%"${_rx_input##*[! ]}"}"
  assert_relay_eq "$_rx_name" "$_rx_want" "$(eval_relay_match "$_rx_input")"
done <<'TABLE'
# match: relay-line forms that purgeLegacyRelayLines must remove
bare-value      | CLAUDE_SESSION_ID=abc                 | match
empty-value     | CLAUDE_SESSION_ID=                    | match
uuid-value      | CLAUDE_SESSION_ID=20661003-current-id | match
# no-match: word-boundary look-alikes must be left untouched
code-prefix     | CLAUDE_CODE_SESSION_ID=abc            | no-match
my-prefix       | MY_CLAUDE_SESSION_ID=abc              | no-match
suffix-extra    | CLAUDE_SESSION_ID_EXTRA=abc           | no-match
export-prefix   | export CLAUDE_SESSION_ID=abc          | no-match
space-in-value  | CLAUDE_SESSION_ID=a b                 | no-match
dot-in-value    | CLAUDE_SESSION_ID=a.b                 | no-match
TABLE
case_end

# ---------------------------------------------------------------------------
case_begin "P5 no relay lines means no write" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p5.env"
printf 'export PATH_EXTRA=/opt/bin\nFOO=bar\n' > "$f"
age_file "$f"
before="$(mtime_of "$f")"
out="$(purge "$(np "$f")")"
after="$(mtime_of "$f")"
if [ "$before" = "$after" ] && [ "$(json_field "$out" changed)" = "false" ]; then
  pass "P5: file without relay lines is not rewritten (mtime unchanged)"
else
  fail "P5: no write without relay lines" "result=$out mtime $before->$after"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P6 missing env file is a no-op" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p6-missing.env"
out="$(purge "$(np "$f")")"
if [ ! -e "$f" ] && [ "$(json_field "$out" changed)" = "false" ]; then
  pass "P6a: purge on a missing path returns changed=false and creates nothing"
else
  fail "P6a: missing path no-op" "result=$out exists=$([ -e "$f" ] && echo yes || echo no)"
fi
case_end

case_begin "P6 missing env file through the hook" "hooks/session-start.js"
f="$TMP_BASE/p6-hook-missing.env"
run_hook "$f" "$HOOK_INPUT"
if [ "$HOOK_RC" -eq 0 ] && hook_out_is_json && [ ! -e "$f" ]; then
  pass "P6b: hook exits 0 with valid JSON and does not create the env file"
else
  fail "P6b: hook with missing env file" "rc=$HOOK_RC exists=$([ -e "$f" ] && echo yes || echo no) out=$(printf '%s' "$HOOK_OUT" | head -c 200)"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P7 env file unset" "hooks/session-start.js"
out="$(purge "__UNSET__")"
if [ "$(json_field "$out" changed)" = "false" ]; then
  pass "P7a: purge with no argument and the variable unset returns changed=false"
else
  fail "P7a: unset variable no-op" "result=$out"
fi
run_hook "__UNSET__" "$HOOK_INPUT"
if [ "$HOOK_RC" -eq 0 ] && hook_out_is_json; then
  pass "P7b: hook exits 0 with valid JSON when the env file variable is unset"
else
  fail "P7b: hook with unset env file variable" "rc=$HOOK_RC out=$(printf '%s' "$HOOK_OUT" | head -c 200)"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P8 empty env file stays empty (relay write abolished)" "hooks/session-start.js"
f="$TMP_BASE/p8.env"
: > "$f"
run_hook "$f" "$HOOK_INPUT"
if [ "$HOOK_RC" -eq 0 ] && [ ! -s "$f" ]; then
  pass "P8: hook appends nothing to an empty env file"
else
  fail "P8: relay write must be gone" "rc=$HOOK_RC content=$(tr '\n' '|' < "$f")"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P9 purge is idempotent" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
f="$TMP_BASE/p9.env"
printf 'CLAUDE_SESSION_ID=one\nKEEP=1\nCLAUDE_SESSION_ID=two\n' > "$f"
out1="$(purge "$(np "$f")")"
cp "$f" "$f.after1"
out2="$(purge "$(np "$f")")"
if [ "$(json_field "$out1" changed)" = "true" ] && [ "$(json_field "$out2" changed)" = "false" ] && cmp -s "$f" "$f.after1"; then
  pass "P9: second purge is a no-op and the file is byte-identical"
else
  fail "P9: idempotency" "first=$out1 second=$out2"
fi
case_end

# ---------------------------------------------------------------------------
# SKIPPED: P10 on Windows (MINGW/MSYS/CYGWIN) and when running as root.
# Because: chmod 444 does not block writes there, so the write-failure branch cannot be forced.
# L3 gap: the write-failure rollback runs only on a POSIX non-root CI host; P12 covers the
# unreadable-path branch everywhere.
case_begin "P10 read-only env file is fail-open" "hooks/session-start.js"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) skip "P10: read-only permission semantics are POSIX-only" ;;
  *)
    if [ "$(id -u)" = "0" ]; then
      skip "P10: running as root bypasses read-only permissions"
    else
      f="$TMP_BASE/p10.env"
      printf 'CLAUDE_SESSION_ID=ro\nKEEP=1\n' > "$f"
      cp "$f" "$f.orig"
      chmod 444 "$f"
      run_hook "$f" "$HOOK_INPUT"
      chmod 644 "$f"
      if [ "$HOOK_RC" -eq 0 ] && hook_out_is_json && cmp -s "$f" "$f.orig"; then
        pass "P10: hook exits 0 and leaves the read-only file unchanged"
      else
        fail "P10: read-only fail-open" "rc=$HOOK_RC content=$(tr '\n' '|' < "$f")"
      fi
    fi
    ;;
esac
case_end

# ---------------------------------------------------------------------------
case_begin "P12 unreadable env path and whitespace path" "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
d="$TMP_BASE/p12-dir.env"
mkdir -p "$d"
out="$(purge "$(np "$d")")"
if [ -d "$d" ] && [ "$(json_field "$out" changed)" = "false" ]; then
  pass "P12a: a directory at the env path is a fail-open no-op"
else
  fail "P12a: directory at env path" "result=$out"
fi
mkdir -p "$TMP_BASE/dir with space"
f="$TMP_BASE/dir with space/p12 space.env"
printf 'CLAUDE_SESSION_ID=sp\nKEEP=sp\n' > "$f"
out="$(purge "$(np "$f")")"
if [ "$(json_field "$out" changed)" = "true" ] && [ "$(cat "$f")" = "KEEP=sp" ]; then
  pass "P12b: env file path containing spaces is purged"
else
  fail "P12b: whitespace path" "result=$out content=$(tr '\n' '|' < "$f")"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "P11 purge runs regardless of session_id in hook input" "hooks/session-start.js"
f="$TMP_BASE/p11.env"
printf 'CLAUDE_SESSION_ID=stale\nKEEP=p11\n' > "$f"
run_hook "$f" '{"hook_event_name":"SessionStart"}'
if [ "$HOOK_RC" -eq 0 ] && hook_out_is_json && [ "$(cat "$f")" = "KEEP=p11" ]; then
  pass "P11a: no session_id field — relay lines purged, hook exits 0"
else
  fail "P11a: no session_id field" "rc=$HOOK_RC content=$(tr '\n' '|' < "$f")"
fi
printf 'CLAUDE_SESSION_ID=stale\nKEEP=p11b\n' > "$f"
run_hook "$f" '{"session_id":"","hook_event_name":"SessionStart"}'
if [ "$HOOK_RC" -eq 0 ] && hook_out_is_json && [ "$(cat "$f")" = "KEEP=p11b" ]; then
  pass "P11b: empty session_id — relay lines purged, hook exits 0"
else
  fail "P11b: empty session_id" "rc=$HOOK_RC content=$(tr '\n' '|' < "$f")"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "I1 SessionStart purges relay lines end to end" "hooks/session-start.js"
f="$TMP_BASE/i1.env"
printf 'CLAUDE_SESSION_ID=stale-1\nexport KEEP_ME=1\nCLAUDE_SESSION_ID=stale-2\n' > "$f"
run_hook "$f" "$HOOK_INPUT"
if [ "$HOOK_RC" -eq 0 ] && hook_out_is_json && [ "$(cat "$f")" = "export KEEP_ME=1" ]; then
  pass "I1: session-start.js removed every relay line and kept the rest"
else
  fail "I1: SessionStart purge" "rc=$HOOK_RC content=$(tr '\n' '|' < "$f")"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
