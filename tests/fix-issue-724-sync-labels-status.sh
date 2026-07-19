#!/bin/bash
# Tests: bin/github-issues/sync-labels.sh, tests/fixtures/gh-mock/gh
# Tags: github, labels, sync, three-way-status
# Tests for issue #724 — three-way create/update/already-exists status in sync-labels.sh.
#
# RED: these S-series tests fail against the current sync-labels.sh (which
# always passes --force). They will PASS once the three-way diff logic lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="$AGENTS_DIR/bin/github-issues/sync-labels.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Ensure mock helpers are executable.
for f in gh git doc-append; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

# ----------------------------------------------------------------------------
# Fixture helpers
# ----------------------------------------------------------------------------

# setup_sync_tmp <labels.yml-content>
# Creates a temp dir, writes labels.yml with the given content, sets up
# PATH/LOG/LIST env vars. Caller may override GH_MOCK_LABEL_LIST afterward.
setup_sync_tmp() {
    TMP="$(mktemp -d)"
    LABELS_FILE="$TMP/labels.yml"
    printf '%s' "$1" > "$LABELS_FILE"

    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_LABEL_LOG="$TMP/labels.log"
    : > "$GH_MOCK_LABEL_LOG"
    unset GH_MOCK_LABEL_LIST
    unset GH_MOCK_LABEL_LIST_FAIL
}

teardown_sync_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    unset TMP LABELS_FILE GH_MOCK_LABEL_LOG GH_MOCK_LABEL_LIST GH_MOCK_LABEL_LIST_FAIL
}

# Canonical 3-label labels.yml used by S1/S2/S3/S4.
THREE_LABELS_YML='- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."

- name: "type:incident"
  color: "d93f0b"
  description: "Incident or bug."

- name: "status:cancelled"
  color: "bfbfbf"
  description: "Cancelled without completion."
'

# 4-label labels.yml used by S5 (mixed).
FOUR_LABELS_YML='- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."

- name: "type:incident"
  color: "d93f0b"
  description: "Incident or bug."

- name: "status:cancelled"
  color: "bfbfbf"
  description: "Cancelled without completion."

- name: "intent:clarified"
  color: "1d76db"
  description: "Issue body ratified."
'

TWO_LABELS_YML='- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."

- name: "type:incident"
  color: "d93f0b"
  description: "Incident or bug."
'

ONE_LABEL_YML='- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."
'

# ============================================================================
# S-series — three-way status (issue #724)
# ============================================================================

# --- S1: all-new — empty remote, 3 labels in yml → 3 created, none --force.
setup_sync_tmp "$THREE_LABELS_YML"
OUT="$TMP/s1.out"
ERRFILE="$TMP/s1.err"
unset GH_MOCK_LABEL_LIST
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>"$ERRFILE"
RC=$?
created_count=$(grep -c '(created)' "$OUT" 2>/dev/null; true)
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
log_force=$(grep -c -- '--force' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '3 created, 0 updated, 0 already-exists, 0 deleted / 3 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$created_count" -eq 3 ] && [ "$log_total" -eq 3 ] \
   && [ "$log_force" -eq 0 ] && [ "$has_summary" -eq 1 ]; then
    pass "S1: all-new — 3 created (no --force), summary '3 created, 0 updated, 0 already-exists, 0 deleted / 3 total'"
else
    fail "S1: rc=$RC created=$created_count log_total=$log_total log_force=$log_force summary_hit=$has_summary"
fi
teardown_sync_tmp

# --- S2: all-existing-unchanged — 3 labels match yml exactly → 0 calls, 3 already-exists.
setup_sync_tmp "$THREE_LABELS_YML"
OUT="$TMP/s2.out"
export GH_MOCK_LABEL_LIST="type:task	0e8a16	Normal work item.
type:incident	d93f0b	Incident or bug.
status:cancelled	bfbfbf	Cancelled without completion."
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
exists_count=$(grep -c '(already exists)' "$OUT" 2>/dev/null; true)
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 3 already-exists, 0 deleted / 3 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$exists_count" -eq 3 ] && [ "$log_total" -eq 0 ] \
   && [ "$has_summary" -eq 1 ]; then
    pass "S2: all-existing-unchanged — 0 API calls, 3 already-exists"
else
    fail "S2: rc=$RC exists=$exists_count log_total=$log_total summary_hit=$has_summary"
fi
teardown_sync_tmp

# --- S3: color-change — 1 label has different color → update with --force.
setup_sync_tmp "$THREE_LABELS_YML"
OUT="$TMP/s3.out"
# type:task remote color differs ("ff0000" vs yml "0e8a16"). Others match.
export GH_MOCK_LABEL_LIST="type:task	ff0000	Normal work item.
type:incident	d93f0b	Incident or bug.
status:cancelled	bfbfbf	Cancelled without completion."
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
updated_count=$(grep -c '(updated)' "$OUT" 2>/dev/null; true)
exists_count=$(grep -c '(already exists)' "$OUT" 2>/dev/null; true)
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
log_force=$(grep -c -- '--force' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
updated_is_task=$(grep -E 'type:task.*\(updated\)' "$OUT" | wc -l | tr -d ' ')
has_summary=$(grep -c '0 created, 1 updated, 2 already-exists, 0 deleted / 3 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$updated_count" -eq 1 ] && [ "$exists_count" -eq 2 ] \
   && [ "$log_total" -eq 1 ] && [ "$log_force" -eq 1 ] \
   && [ "$updated_is_task" -ge 1 ] && [ "$has_summary" -eq 1 ]; then
    pass "S3: color-change — 1 (updated) with --force, 2 (already exists)"
else
    fail "S3: rc=$RC updated=$updated_count exists=$exists_count log_total=$log_total log_force=$log_force updated_is_task=$updated_is_task summary_hit=$has_summary"
fi
teardown_sync_tmp

# --- S4: description-change — 1 label has different description → update with --force.
setup_sync_tmp "$THREE_LABELS_YML"
OUT="$TMP/s4.out"
# type:incident remote description differs.
export GH_MOCK_LABEL_LIST="type:task	0e8a16	Normal work item.
type:incident	d93f0b	Old description.
status:cancelled	bfbfbf	Cancelled without completion."
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
updated_count=$(grep -c '(updated)' "$OUT" 2>/dev/null; true)
exists_count=$(grep -c '(already exists)' "$OUT" 2>/dev/null; true)
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
log_force=$(grep -c -- '--force' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
updated_is_incident=$(grep -E 'type:incident.*\(updated\)' "$OUT" | wc -l | tr -d ' ')
has_summary=$(grep -c '0 created, 1 updated, 2 already-exists, 0 deleted / 3 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$updated_count" -eq 1 ] && [ "$exists_count" -eq 2 ] \
   && [ "$log_total" -eq 1 ] && [ "$log_force" -eq 1 ] \
   && [ "$updated_is_incident" -ge 1 ] && [ "$has_summary" -eq 1 ]; then
    pass "S4: description-change — 1 (updated) with --force, 2 (already exists)"
else
    fail "S4: rc=$RC updated=$updated_count exists=$exists_count log_total=$log_total log_force=$log_force updated_is_incident=$updated_is_incident summary_hit=$has_summary"
fi
teardown_sync_tmp

# --- S5: mixed — 1 new + 1 unchanged + 1 color-diff + 1 desc-diff over 4-label yml.
setup_sync_tmp "$FOUR_LABELS_YML"
OUT="$TMP/s5.out"
# Remote: type:task matches (unchanged), type:incident has different color,
# status:cancelled has different description, intent:clarified absent (new).
export GH_MOCK_LABEL_LIST="type:task	0e8a16	Normal work item.
type:incident	ff0000	Incident or bug.
status:cancelled	bfbfbf	Old description here."
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
created_count=$(grep -c '(created)' "$OUT" 2>/dev/null; true)
updated_count=$(grep -c '(updated)' "$OUT" 2>/dev/null; true)
exists_count=$(grep -c '(already exists)' "$OUT" 2>/dev/null; true)
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
log_force=$(grep -c -- '--force' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '1 created, 2 updated, 1 already-exists, 0 deleted / 4 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$created_count" -eq 1 ] && [ "$updated_count" -eq 2 ] \
   && [ "$exists_count" -eq 1 ] && [ "$log_total" -eq 3 ] && [ "$log_force" -eq 2 ] \
   && [ "$has_summary" -eq 1 ]; then
    pass "S5: mixed — 1 created + 2 updated + 1 already-exists / 4 total"
else
    fail "S5: rc=$RC created=$created_count updated=$updated_count exists=$exists_count log_total=$log_total log_force=$log_force summary_hit=$has_summary"
fi
teardown_sync_tmp

# --- S6: gh label list failure → script aborts, exit nonzero, stderr message.
setup_sync_tmp "$THREE_LABELS_YML"
OUT="$TMP/s6.out"
ERRFILE="$TMP/s6.err"
export GH_MOCK_LABEL_LIST_FAIL=1
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>"$ERRFILE"
RC=$?
ERR=$(cat "$ERRFILE" 2>/dev/null)
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
if [ "$RC" -ne 0 ] && [ -n "$ERR" ] && [ "$log_total" -eq 0 ]; then
    pass "S6: gh label list failure — non-zero exit, stderr message, no create calls"
else
    fail "S6: rc=$RC err='$ERR' log_total=$log_total"
fi
teardown_sync_tmp

# --- S7: empty labels.yml → 0 entries, no API calls, "0/0/0 / 0 total".
setup_sync_tmp "# only a comment, no entries
"
OUT="$TMP/s7.out"
unset GH_MOCK_LABEL_LIST
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
log_total=$(grep -c 'label create' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 0 already-exists, 0 deleted / 0 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$log_total" -eq 0 ] && [ "$has_summary" -eq 1 ]; then
    pass "S7: empty labels.yml — no API calls, summary '0/0/0/0 / 0 total'"
else
    fail "S7: rc=$RC log_total=$log_total summary_hit=$has_summary"
fi
teardown_sync_tmp

# --- S8: DELETE basic — orphaned label deleted.
setup_sync_tmp "$TWO_LABELS_YML"
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\ntype:incident\td93f0b\tIncident or bug.\nstale:old\taaaaaa\tOld stale label.'
OUT="$TMP/s8.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
deleted_count=$(grep -c '(deleted)' "$OUT" 2>/dev/null; true)
delete_logged=$(grep -c 'label delete stale:old' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 2 already-exists, 1 deleted / 3 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$deleted_count" -ge 1 ] && [ "$delete_logged" -ge 1 ] \
   && [ "$has_summary" -eq 1 ]; then
    pass "S8: DELETE basic — stale:old deleted, log recorded, summary correct"
else
    fail "S8: rc=$RC deleted_count=$deleted_count delete_logged=$delete_logged summary=$has_summary out=$(cat "$OUT")"
fi
teardown_sync_tmp

# --- S9: DELETE --dry-run — gh label delete NOT called.
setup_sync_tmp "$ONE_LABEL_YML"
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\nghost:label\tbbbbbb\tGhost label.'
OUT="$TMP/s9.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" --dry-run "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
dryrun_msg=$(grep -c '\[DRY-RUN\] Would delete: ghost:label' "$OUT" 2>/dev/null; true)
delete_logged=$(grep -c 'label delete' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 1 already-exists, 1 deleted / 2 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$dryrun_msg" -ge 1 ] && [ "$delete_logged" -eq 0 ] \
   && [ "$has_summary" -eq 1 ]; then
    pass "S9: DELETE --dry-run — dry-run msg shown, no gh call, summary correct"
else
    fail "S9: rc=$RC dryrun_msg=$dryrun_msg delete_logged=$delete_logged summary=$has_summary out=$(cat "$OUT")"
fi
teardown_sync_tmp

# --- S10: no DELETE — remote matches yml exactly.
setup_sync_tmp "$TWO_LABELS_YML"
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\ntype:incident\td93f0b\tIncident or bug.'
OUT="$TMP/s10.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
delete_logged=$(grep -c 'label delete' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 2 already-exists, 0 deleted / 2 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$delete_logged" -eq 0 ] && [ "$has_summary" -eq 1 ]; then
    pass "S10: no DELETE — remote matches yml, no delete calls, summary correct"
else
    fail "S10: rc=$RC delete_logged=$delete_logged summary=$has_summary out=$(cat "$OUT")"
fi
teardown_sync_tmp

# --- S11: DELETE multiple — 3 orphaned labels deleted.
setup_sync_tmp "$ONE_LABEL_YML"
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\nold:a\taaaaaa\tOld A.\nold:b\tbbbbbb\tOld B.\nold:c\tcccccc\tOld C.'
OUT="$TMP/s11.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
delete_logged=$(grep -c 'label delete' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 1 already-exists, 3 deleted / 4 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$delete_logged" -ge 3 ] && [ "$has_summary" -eq 1 ]; then
    pass "S11: DELETE multiple — 3 labels deleted, summary correct"
else
    fail "S11: rc=$RC delete_logged=$delete_logged summary=$has_summary out=$(cat "$OUT")"
fi
teardown_sync_tmp

# --- S12: --no-delete — gh label delete not called, NO-DELETE message shown.
setup_sync_tmp "$TWO_LABELS_YML"
# Remote: type:task + type:incident (match) + ghost:label (orphan → DELETE 候補)
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\ntype:incident\td93f0b\tIncident or bug.\nghost:label\tbbbbbb\tGhost label.'
OUT="$TMP/s12.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" --no-delete "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
delete_logged=$(grep -c 'label delete' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
nodelete_msg=$(grep -c '\[NO-DELETE\] Skipped delete: ghost:label' "$OUT" 2>/dev/null; true)
has_summary=$(grep -c '0 created, 0 updated, 2 already-exists, 1 deleted / 3 total' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$delete_logged" -eq 0 ] \
   && [ "$nodelete_msg" -ge 1 ] && [ "$has_summary" -eq 1 ]; then
    pass "S12: --no-delete — gh label delete not called, NO-DELETE msg shown, summary correct"
else
    fail "S12: rc=$RC delete_logged=$delete_logged nodelete_msg=$nodelete_msg summary=$has_summary out=$(cat "$OUT")"
fi
teardown_sync_tmp

# --- S13: protected label — never deleted even in normal sync (no --no-delete).
PROTECTED_LABELS_YML='- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."

protected:
  - bug
  - enhancement
'
setup_sync_tmp "$PROTECTED_LABELS_YML"
# Remote: type:task (match) + bug (protected) + old:stale (orphan, not protected → DELETE)
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\nbug\tee0701\tSomething is not working.\nold:stale\taaaaaa\tStale label.'
OUT="$TMP/s13.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
bug_deleted=$(grep -c 'label delete.*bug' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
bug_deleted_out=$(grep -c 'bug (deleted)' "$OUT" 2>/dev/null; true)
stale_deleted=$(grep -c 'label delete' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
stale_deleted_out=$(grep -c 'old:stale (deleted)' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$bug_deleted" -eq 0 ] && [ "$bug_deleted_out" -eq 0 ] \
   && [ "$stale_deleted" -ge 1 ] && [ "$stale_deleted_out" -ge 1 ]; then
    pass "S13: protected label — bug not deleted (protected), old:stale deleted (not protected)"
else
    fail "S13: rc=$RC bug_deleted=$bug_deleted bug_deleted_out=$bug_deleted_out stale_deleted=$stale_deleted stale_deleted_out=$stale_deleted_out out=$(cat "$OUT")"
fi
teardown_sync_tmp

# --- S14: protected label with spaces — "good first issue" not deleted.
PROTECTED_SPACES_YML='- name: "type:task"
  color: "0e8a16"
  description: "Normal work item."

protected:
  - "good first issue"
  - "help wanted"
'
setup_sync_tmp "$PROTECTED_SPACES_YML"
# Remote: type:task (match) + "good first issue" (protected) + old:cruft (not protected → DELETE)
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal work item.\ngood first issue\t7057ff\tGood for newcomers.\nold:cruft\tcccccc\tOld cruft label.'
OUT="$TMP/s14.out"
run_with_timeout 30 bash "$SYNC_SCRIPT" "$LABELS_FILE" >"$OUT" 2>&1
RC=$?
gfi_deleted=$(grep -c 'label delete.*good first issue' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
gfi_deleted_out=$(grep -c 'good first issue (deleted)' "$OUT" 2>/dev/null; true)
cruft_deleted=$(grep -c 'label delete' "$GH_MOCK_LABEL_LOG" 2>/dev/null; true)
cruft_deleted_out=$(grep -c 'old:cruft (deleted)' "$OUT" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$gfi_deleted" -eq 0 ] && [ "$gfi_deleted_out" -eq 0 ] \
   && [ "$cruft_deleted" -ge 1 ] && [ "$cruft_deleted_out" -ge 1 ]; then
    pass "S14: protected label with spaces — 'good first issue' not deleted, old:cruft deleted"
else
    fail "S14: rc=$RC gfi_deleted=$gfi_deleted gfi_deleted_out=$gfi_deleted_out cruft_deleted=$cruft_deleted cruft_deleted_out=$cruft_deleted_out out=$(cat "$OUT")"
fi
teardown_sync_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
