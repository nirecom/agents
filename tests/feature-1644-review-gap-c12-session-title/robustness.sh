# shellcheck shell=bash
# Tests: hooks/lib/session-title.js
# Tags: tl2, workflow, session-title, jsonl, idempotency, scope:issue-specific, pwsh-not-required
# C12-3 (JSONL robustness), C12-4 (idempotency), C12-5 (suppression guards).
# Relies on helpers.sh being sourced first.

run_robustness_cases() {
echo ""
echo "=== C12-3: JSONL robustness ==="
SID=j1; JSONL="$JSONL_DIR/$SID.jsonl"
{
  echo 'not json at all'
  echo '{"type":"custom-title","sessionId":"j1"'          # truncated JSON
  echo '{"type":"user","sessionId":"j1","text":"hello"}'   # non-title record
  echo ''                                                  # blank line
  echo '{"type":"custom-title","sessionId":"other","customTitle":"#1 Other session"}'
  echo '{"type":"custom-title","sessionId":"j1","customTitle":123}'  # wrong type
} > "$JSONL"
write_intent "$SID" '## Issues

- #42: Title over malformed jsonl
'
call "$JSONL" "m.writeSetIssue('$SID','$CWD_ARG_N','$PLANS_DIR_N');" >/dev/null
check "C12-3a: malformed lines / foreign sessions / wrong types are ignored -> treated as no title" \
  "#42 Title over malformed jsonl" "$(last_title "$JSONL" "$SID")"

# ABSENT transcript directory: the JSONL path points into a directory that does
# not exist. Every writer must fail open (no throw, no crash, no write).
SID=j2; MISSING_JSONL="$TMPDIR_BASE/no-such-dir/$SID.jsonl"
write_intent "$SID" '## Issues

- #42: Never written
'
OUT="$(call "$MISSING_JSONL" "m.writeSetIssue('$SID','$CWD_ARG_N','$PLANS_DIR_N');")"
check "C12-3b: writeSetIssue fails open when the transcript dir is absent" "" "$OUT"
OUT="$(call "$MISSING_JSONL" "m.writeAddPr('$SID','$CWD_ARG_N',99);")"
check "C12-3c: writeAddPr fails open when the transcript dir is absent" "" "$OUT"
OUT="$(call "$MISSING_JSONL" "m.writeMarkComplete('$SID','$CWD_ARG_N');")"
check "C12-3d: writeMarkComplete fails open when the transcript dir is absent" "" "$OUT"
if [ -e "$MISSING_JSONL" ]; then
  fail "C12-3e: the missing transcript directory was created by a writer"
else
  pass "C12-3e: no transcript directory or file was created"
fi

echo ""
echo "=== C12-4: repeated application is idempotent ==="
SID=i1; JSONL="$JSONL_DIR/$SID.jsonl"; : > "$JSONL"
write_intent "$SID" '## Issues

- #42: Idempotency subject
'
call "$JSONL" "m.writeSetIssue('$SID','$CWD_ARG_N','$PLANS_DIR_N');" >/dev/null
call "$JSONL" "m.writeAddPr('$SID','$CWD_ARG_N',1900);" >/dev/null
AFTER_ONE="$(last_title "$JSONL" "$SID")"
COUNT_ONE="$(title_records "$JSONL")"
call "$JSONL" "m.writeAddPr('$SID','$CWD_ARG_N',1900);" >/dev/null
call "$JSONL" "m.writeAddPr('$SID','$CWD_ARG_N',1900);" >/dev/null
check "C12-4a: the PR suffix is applied exactly once" \
  "#42 Idempotency subject PR #1900" "$(last_title "$JSONL" "$SID")"
check "C12-4b: no further records are appended by repeat PR calls" \
  "$COUNT_ONE" "$(title_records "$JSONL")"
check "C12-4c: sanity -- the first application did produce the suffix" \
  "#42 Idempotency subject PR #1900" "$AFTER_ONE"

# A DIFFERENT PR number is not idempotent -- it appends a second suffix. Pinned
# so the idempotency claim is not read as "PR suffixes are deduped".
call "$JSONL" "m.writeAddPr('$SID','$CWD_ARG_N',1901);" >/dev/null
check "C12-4d: a different PR number appends another suffix (pinned)" \
  "#42 Idempotency subject PR #1900 PR #1901" "$(last_title "$JSONL" "$SID")"

call "$JSONL" "m.writeMarkComplete('$SID','$CWD_ARG_N');" >/dev/null
MARKED="$(last_title "$JSONL" "$SID")"
COUNT_MARKED="$(title_records "$JSONL")"
call "$JSONL" "m.writeMarkComplete('$SID','$CWD_ARG_N');" >/dev/null
call "$JSONL" "m.writeMarkComplete('$SID','$CWD_ARG_N');" >/dev/null
check "C12-4e: the completion mark is applied exactly once" "$MARKED" "$(last_title "$JSONL" "$SID")"
check "C12-4f: no further records are appended by repeat completion calls" \
  "$COUNT_MARKED" "$(title_records "$JSONL")"
check "C12-4g: sanity -- the completion mark is the ✓ prefix" \
  "✓ #42 Idempotency subject PR #1900 PR #1901" "$MARKED"

# writeAddPr AFTER completion still appends (the ✓ prefix is preserved).
call "$JSONL" "m.writeAddPr('$SID','$CWD_ARG_N',2000);" >/dev/null
check "C12-4h: a PR suffix after completion keeps the ✓ prefix" \
  "✓ #42 Idempotency subject PR #1900 PR #1901 PR #2000" "$(last_title "$JSONL" "$SID")"

# writeMarkComplete over a bare "⏳" strips the sentinel rather than prefixing it.
SID=i2; JSONL="$JSONL_DIR/$SID.jsonl"; : > "$JSONL"
node -e '
  const fs=require("fs");
  fs.appendFileSync(process.argv[1], JSON.stringify({type:"custom-title",sessionId:process.argv[2],customTitle:"⏳"})+"\n");
' "$(nrm "$JSONL")" "$SID"
call "$JSONL" "m.writeMarkComplete('$SID','$CWD_ARG_N');" >/dev/null
check "C12-4i: completion over a bare ⏳ yields a bare ✓" "✓" "$(last_title "$JSONL" "$SID")"

echo ""
echo "=== C12-5: suppression guards hold for all three writers (CPR-ORTH) ==="
# Child session: CLAUDE_CODE_CHILD_SESSION === "1" suppresses every write.
run_child_case() {
  local name="$1" envval="$2" want_count="$3" idx="$4"
  local sid="c-$idx"
  local jsonl="$JSONL_DIR/${sid}.jsonl"; : > "$jsonl"
  write_intent "$sid" '## Issues

- #42: Child guard subject
'
  local before after
  before="$(title_records "$jsonl")"
  CLAUDE_CODE_CHILD_SESSION="$envval" ST_MODULE="$ST_MODULE_N" \
    ST_CALL="m.writeSetIssue('$sid','$CWD_ARG_N','$PLANS_DIR_N'); m.writeAddPr('$sid','$CWD_ARG_N',9); m.writeMarkComplete('$sid','$CWD_ARG_N');" \
    CLAUDE_SESSION_JSONL_PATH="$(nrm "$jsonl")" run_with_timeout node "$PROBE" >/dev/null 2>&1
  after="$(title_records "$jsonl")"
  check "C12-5 $name" "$want_count" "$((after - before))"
}
run_child_case "CLAUDE_CODE_CHILD_SESSION=1 suppresses all three writers" "1" 0 1
run_child_case "=0 is NOT the guard value -- writers run"                 "0" 3 2
run_child_case "=true is NOT the guard value -- writers run"           "true" 3 3

# Empty sessionId: every writer returns early, no record appended.
EMPTY_JSONL="$JSONL_DIR/empty-sid.jsonl"; : > "$EMPTY_JSONL"
call "$EMPTY_JSONL" "m.writeSetIssue('','$CWD_ARG_N','$PLANS_DIR_N'); m.writeAddPr('','$CWD_ARG_N',9); m.writeMarkComplete('','$CWD_ARG_N');" >/dev/null
check "C12-5d: an empty sessionId suppresses all three writers" "0" "$(title_records "$EMPTY_JSONL")"
# undefined/null sessionId is the same falsy branch -- must not throw.
OUT="$(call "$EMPTY_JSONL" "m.writeSetIssue(undefined,'$CWD_ARG_N','$PLANS_DIR_N'); m.writeAddPr(null,'$CWD_ARG_N',9); m.writeMarkComplete(undefined,'$CWD_ARG_N');")"
check "C12-5e: undefined/null sessionId does not throw" "" "$OUT"
check "C12-5f: undefined/null sessionId writes nothing" "0" "$(title_records "$EMPTY_JSONL")"
}
