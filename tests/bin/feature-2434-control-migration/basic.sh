#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/basic.sh
# Tests: hooks/lib/temporary-migrations/control-dir-split/index.js, bin/migrate-control-dir, hooks/lib/plans-artifact-registry.js
# Tags: TL2, scope:issue-specific, control-dir, migration, basic
# TL3 gap (what this test does NOT catch):
# - mtime preservation on NTFS with 100ns granularity vs ext4 1s granularity
# - Cross-filesystem link semantics
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: migration

set -uo pipefail
_BASIC_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$_BASIC_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_mtime.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

IDX_MOD="$(np "$_BASIC_SCRIPT_CHECKOUT_ROOT/hooks/lib/temporary-migrations/control-dir-split/index.js")"
MIGRATE_CLI="$_BASIC_SCRIPT_CHECKOUT_ROOT/bin/migrate-control-dir"

# Helper: run migrateSession via node, returns "OK:<count>" or "ERR:<msg>"
run_migrate_session() {
  local sid="$1" wf_dir="$2" plans_dir="$3"
  node -e "
process.env.WORKFLOW_STATE_DIR='$wf_dir';
process.env.WORKFLOW_PLANS_DIR='$plans_dir';
try {
  var m=require('$IDX_MOD');
  m.migrateSession('$sid').then(function(r){
    process.stdout.write('OK:'+String(Array.isArray(r)?r.length:'?'));
    process.exit(0);
  }).catch(function(e){
    process.stdout.write('PROMISE_ERR:'+String((e&&e.message)||e).split('\n')[0]);
    process.exit(0);
  });
} catch(e) {
  process.stdout.write('ERR:'+String(e.code||e.message).split('\n')[0]);
  process.exit(0);
}
" 2>/dev/null
}

UUID="aabbccdd-1111-2222-3333-444455556666"

case_begin "single-sid-cli-migrate" "bin/migrate-control-dir"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal-content\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '2\n' > "$T/plans/${SID}-detail-plan-round-number.txt"
if [ ! -f "$MIGRATE_CLI" ]; then
  fail "single-sid-cli-migrate" "bin/migrate-control-dir not found (implementation absent)"
else
  node "$MIGRATE_CLI" --session "$SID" 2>/dev/null
  rc=$?
  DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
  if [ "$rc" -ne 0 ]; then
    fail "single-sid-cli-migrate:exit" "expected 0 got $rc"
  elif [ ! -f "$DST" ]; then
    fail "single-sid-cli-migrate:dst-missing" "destination not created: $DST"
  elif [ -f "$T/plans/${SID}-detail-plan-terminal.txt" ]; then
    fail "single-sid-cli-migrate:src-not-removed" "legacy file still present"
  else
    pass "single-sid-cli-migrate"
  fi
fi
rm -rf "$T"
case_end

case_begin "single-sid-js-migrate" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal-js\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
if printf '%s' "$RES" | grep -q '^OK:'; then
  if [ -f "$DST" ]; then pass "single-sid-js-migrate:dst-exists"
  else fail "single-sid-js-migrate:dst-missing" "destination not created after JS migrate"; fi
  if [ -f "$T/plans/${SID}-detail-plan-terminal.txt" ]; then
    fail "single-sid-js-migrate:src-not-removed" "legacy file still present"
  else
    pass "single-sid-js-migrate:src-removed"
  fi
else
  fail "single-sid-js-migrate" "migrateSession failed: $RES"
fi
rm -rf "$T"
case_end

case_begin "content-equal-after-migrate" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'exact-content-xyz\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
if [ -f "$DST" ]; then
  GOT=$(cat "$DST" 2>/dev/null || echo missing)
  assert_eq "$GOT" "exact-content-xyz"
else
  fail "content-equal-after-migrate" "destination file missing"
fi
rm -rf "$T"
case_end

case_begin "mtime-preserved" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'mt\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
# Aged well into the past, so "preserved" cannot pass by the copy landing in the same second.
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt"
BEFORE=$(file_mtime "$T/plans/${SID}-detail-plan-terminal.txt")
run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
AFTER=$(file_mtime "$DST")
if [ "$BEFORE" -eq 0 ] || [ "$AFTER" -eq 0 ]; then
  fail "mtime-preserved" "could not read mtime"
elif [ "$BEFORE" -ne "$AFTER" ]; then
  fail "mtime-preserved" "mtime changed: before=$BEFORE after=$AFTER"
else
  pass "mtime-preserved"
fi
rm -rf "$T"
case_end

case_begin "idempotence" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'idem\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
# Aged first, so a rewrite on the second run is visible even within the same second.
age_files 700 "$DST"
MT1=$(file_mtime "$DST")
RES2=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
MT2=$(file_mtime "$DST")
if [ "$MT1" -eq 0 ] || [ "$MT2" -eq 0 ]; then
  fail "idempotence" "could not read dst mtime (first run did not publish?)"
elif printf '%s' "$RES2" | grep -q '^ERR:'; then
  fail "idempotence" "second run failed: $RES2"
elif [ "$MT1" -ne "$MT2" ]; then
  fail "idempotence:mtime-changed" "dst mtime changed on second run"
else
  pass "idempotence"
fi
rm -rf "$T"
case_end

case_begin "sid-date-form" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="20260601-120000"
printf 'date-terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '1\n' > "$T/plans/${SID}-detail-plan-round-number.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
if printf '%s' "$RES" | grep -q '^OK:'; then
  if [ -f "$DST" ]; then pass "sid-date-form"
  else fail "sid-date-form" "dst missing after date-form sid migration"; fi
else
  fail "sid-date-form" "$RES"
fi
rm -rf "$T"
case_end

case_begin "sid-derived-form" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
BASE="aabbccdd-1111-2222-3333-444455556666"
SID="${BASE}-b1"
printf 'derived-terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
if printf '%s' "$RES" | grep -q '^OK:'; then
  if [ -f "$DST" ]; then pass "sid-derived-form"
  else fail "sid-derived-form" "dst missing for derived sid"; fi
else
  fail "sid-derived-form" "$RES"
fi
rm -rf "$T"
case_end

case_begin "sid-bundle-form" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="20260509-bundle-a"
printf 'bundle-terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
if printf '%s' "$RES" | grep -q '^OK:'; then
  if [ -f "$DST" ]; then pass "sid-bundle-form"
  else fail "sid-bundle-form" "dst missing for bundle sid"; fi
else
  fail "sid-bundle-form" "$RES"
fi
rm -rf "$T"
case_end

case_begin "no-cross-sid-migration" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
BASE="aabbccdd-1111-2222-3333-444455556666"
DERIVED="${BASE}-b1"
printf 'base-terminal\n' > "$T/plans/${BASE}-detail-plan-terminal.txt"
printf 'derived-terminal\n' > "$T/plans/${DERIVED}-detail-plan-terminal.txt"
RES=$(run_migrate_session "$BASE" "$(np "$T/workflow-state")" "$(np "$T/plans")")
if printf '%s' "$RES" | grep -q '^OK:'; then
  if [ -f "$T/plans/${DERIVED}-detail-plan-terminal.txt" ]; then
    pass "no-cross-sid-migration"
  else
    fail "no-cross-sid-migration" "derived sid file was incorrectly moved by base sid migration"
  fi
else
  fail "no-cross-sid-migration" "migrateSession failed: $RES"
fi
rm -rf "$T"
case_end

case_begin "artifact-stays-in-plans" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '# detail plan\n' > "$T/plans/${SID}-detail.md"
printf '# context\n' > "$T/plans/${SID}-context.md"
run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
if [ -f "$T/plans/${SID}-detail.md" ]; then
  pass "artifact-stays-in-plans:detail"
else
  fail "artifact-stays-in-plans:detail" "detail.md was moved out of PLANS_DIR"
fi
if [ -f "$T/plans/${SID}-context.md" ]; then
  pass "artifact-stays-in-plans:context"
else
  fail "artifact-stays-in-plans:context" "context.md was moved out of PLANS_DIR"
fi
rm -rf "$T"
case_end

case_begin "plans-only-artifacts-noop" "bin/migrate-control-dir"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf '# intent\n' > "$T/plans/${SID}-intent.md"
printf '# outline\n' > "$T/plans/${SID}-outline.md"
printf '# detail\n' > "$T/plans/${SID}-detail.md"
if [ ! -f "$MIGRATE_CLI" ]; then
  fail "plans-only-artifacts-noop" "bin/migrate-control-dir not found"
else
  node "$MIGRATE_CLI" --all 2>/dev/null
  rc=$?
  CTRL_DIR="$T/workflow-state/${SID}.control"
  if [ "$rc" -ne 0 ]; then
    fail "plans-only-artifacts-noop:exit" "expected exit 0, got $rc"
  elif [ -d "$CTRL_DIR" ] && [ "$(ls "$CTRL_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    fail "plans-only-artifacts-noop:created-files" "unexpected control files created"
  else
    pass "plans-only-artifacts-noop"
  fi
fi
rm -rf "$T"
case_end

# The kinds table, late arrival and CLI round trip live in a sourced fragment (file-size split).
# shellcheck source=./_basic-kinds-cli.sh
. "$(dirname "${BASH_SOURCE[0]}")/_basic-kinds-cli.sh"

echo ""
echo "basic: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
