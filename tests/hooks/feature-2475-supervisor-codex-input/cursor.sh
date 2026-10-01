# cursor.sh — fragment of tests/hooks/feature-2475-supervisor-codex-input.sh (no frontmatter).
# Plan Step 10, asserted black-box through the CLI: the cursor is read from
#   getStatePath(sid).<mode>.transcript_cursor, and the CLI prints
#   CURSOR_STATUS: <status> and CURSOR_NEXT: <one-line json> on stdout.

CU_T="$SCI_TMP/proj/cur.jsonl"
cu_write_fixture() {
  {
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"cur-one"},"uuid":"u1","timestamp":"2026-01-01T00:00:01Z"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo cur-two"}}]},"uuid":"u2"}'
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"cur-three"},"uuid":"u3","timestamp":"2026-01-01T00:00:03Z"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"echo cur-four"}}]},"uuid":"u4"}'
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"cur-five"},"uuid":"u5","timestamp":"2026-01-01T00:00:05Z"}'
  } > "$CU_T"
}
cu_write_fixture
CU_TN="$(np "$CU_T")"
CU_OUT="$SCI_TMP/cur-out.txt"

echo "--- cursor: fresh (no state) ---"
sci_run "$(np "$CU_OUT")" --mode alert --sid cufresh --wsid UNAVAILABLE --transcript "$CU_TN"
sci_eq "fresh: exit 0" "$SCI_RC" "0"
sci_match "fresh: CURSOR_STATUS: fresh" "$SCI_STDOUT" '^CURSOR_STATUS: fresh$'
sci_eq "fresh: next.line = 5" "$(sci_next_field line)" "5"
sci_eq "fresh: next.last_uuid = u5" "$(sci_next_field last_uuid)" "u5"
CU_NP="$(sci_next_field transcript_path)"
case "$CU_NP" in ""|undefined|PARSE_ERROR) fail "fresh: next.transcript_path set" "got=$CU_NP" ;; *) pass "fresh: next.transcript_path set" ;; esac
sci_match "fresh: next.updated_at is an ISO string" "$(sci_next_field updated_at)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
sci_has "fresh: ACTIONS start at L1" "$(sci_block "$CU_OUT" "ACTIONS SINCE PREVIOUS ALERT RUN")" "cmd: echo cur-two"

echo "--- cursor: resume ---"
sci_mkstate curesume alert "$CU_TN" 3 u3
sci_run "$(np "$CU_OUT")" --mode alert --sid curesume --wsid UNAVAILABLE --transcript "$CU_TN"
sci_match "resume: CURSOR_STATUS: resume" "$SCI_STDOUT" '^CURSOR_STATUS: resume$'
CU_A="$(sci_block "$CU_OUT" "ACTIONS SINCE PREVIOUS ALERT RUN")"
sci_has "resume: ACTIONS include L4" "$CU_A" "cmd: echo cur-four"
sci_lacks "resume: ACTIONS exclude L2 (before cursor)" "$CU_A" "cmd: echo cur-two"
sci_match "resume: ACTIONS lines carry transcript line numbers" "$CU_A" '^L4 .*cmd: echo cur-four'
sci_has "resume: header range L4..L5" "$(sci_header "$CU_OUT")" "L4..L5"
sci_has "resume: header cursor status" "$(sci_header "$CU_OUT")" "cursor: resume"
sci_has "resume: USER UTTERANCES still from L1" "$(sci_block "$CU_OUT" "USER UTTERANCES")" "cur-one"

echo "--- cursor: reset variants ---"
sci_mkstate cumismatch alert "$CU_TN" 3 zz
sci_run "$(np "$CU_OUT")" --mode alert --sid cumismatch --wsid UNAVAILABLE --transcript "$CU_TN"
sci_match "uuid-mismatch: CURSOR_STATUS: reset:uuid-mismatch" "$SCI_STDOUT" '^CURSOR_STATUS: reset:uuid-mismatch$'
sci_has "uuid-mismatch: ACTIONS restart at L1" "$(sci_block "$CU_OUT" "ACTIONS SINCE PREVIOUS ALERT RUN")" "cmd: echo cur-two"

sci_mkstate cutrunc alert "$CU_TN" 9 u5
sci_run "$(np "$CU_OUT")" --mode alert --sid cutrunc --wsid UNAVAILABLE --transcript "$CU_TN"
sci_match "truncated: CURSOR_STATUS: reset:truncated" "$SCI_STDOUT" '^CURSOR_STATUS: reset:truncated$'

sci_mkstate cupath alert "$(np "$SCI_TMP/proj/other.jsonl")" 3 u3
sci_run "$(np "$CU_OUT")" --mode alert --sid cupath --wsid UNAVAILABLE --transcript "$CU_TN"
sci_match "path-changed: CURSOR_STATUS: reset:path-changed" "$SCI_STDOUT" '^CURSOR_STATUS: reset:path-changed$'

echo "--- cursor: trailing fragment is not a complete line ---"
printf '%s' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"partial"},"uuid":"u6"' >> "$CU_T"
sci_run "$(np "$CU_OUT")" --mode alert --sid cufrag --wsid UNAVAILABLE --transcript "$CU_TN"
sci_eq "fragment: exit 0" "$SCI_RC" "0"
sci_eq "fragment: next.line stays 5" "$(sci_next_field line)" "5"
sci_eq "fragment: next.last_uuid stays u5" "$(sci_next_field last_uuid)" "u5"
sci_match "fragment: header does not count it as unparsable" "$(sci_header "$CU_OUT")" 'skipped_unparsable[^0-9]{0,3}0([^0-9]|$)'
cu_write_fixture

echo "--- cursor: win32 path spelling variance ---"
if [ "$(node -p 'process.platform' 2>/dev/null)" = "win32" ] && command -v cygpath >/dev/null 2>&1; then
  CU_WIN="$(cygpath -w "$CU_T")"
  CU_WIN_UP="$(printf '%s' "$CU_WIN" | tr '[:lower:]' '[:upper:]')"
  CU_POSIX_LOW="$(sci_msys_path "$CU_T" | tr '[:upper:]' '[:lower:]')"
  sci_mkstate cuwin alert "$CU_WIN_UP" 3 u3
  SCI_STDOUT="$(sci_run_msys --mode alert --sid cuwin --wsid UNAVAILABLE --transcript "$CU_POSIX_LOW" --out "$(np "$CU_OUT")" 2>&1)"
  sci_match "win32: C:\\X\\T.jsonl cursor vs /c/x/t.jsonl transcript -> resume" "$SCI_STDOUT" '^CURSOR_STATUS: resume$'
else
  skip "win32: path spelling variance (POSIX host)"
fi
