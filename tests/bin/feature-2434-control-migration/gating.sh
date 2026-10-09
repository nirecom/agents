#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/gating.sh
# Tests: hooks/lib/temporary-migrations/control-dir-split/plan.js, hooks/lib/temporary-migrations/control-dir-split/index.js
# Tags: TL2, scope:issue-specific, control-dir, migration, gating
# TL3 gap: MIGRATABLE_KINDS behavior on production hosts with edge-case filenames.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight category: migration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_mtime.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

IDX_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/temporary-migrations/control-dir-split/index.js")"
UUID="aabbccdd-1111-2222-3333-444455556666"

run_migrate_all() {
  local wf="$1" plans="$2"
  node -e "
process.env.WORKFLOW_STATE_DIR='$wf';
process.env.WORKFLOW_PLANS_DIR='$plans';
try {
  var m=require('$IDX_MOD');
  Promise.resolve(m.migrateAll({budgetMs:5000})).then(function(){
    process.stdout.write('OK');
    process.exit(0);
  }).catch(function(e){
    process.stdout.write('ERR:'+String((e&&e.message)||e).split('\n')[0]);
    process.exit(0);
  });
} catch(e) {
  process.stdout.write('ERR:'+String(e.code||e.message).split('\n')[0]);
  process.exit(0);
}
" 2>/dev/null
}

case_begin "gating-unregistered-stays" "hooks/lib/temporary-migrations/control-dir-split/plan.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf '# context\n' > "$T/plans/${SID}-context.md"
printf 'unregistered-value\n' > "$T/plans/${SID}-foo.md"
run_migrate_all "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
if [ -f "$T/plans/${SID}-foo.md" ]; then
  pass "gating-unregistered-stays"
else
  fail "gating-unregistered-stays" "unregistered file should not be moved"
fi
rm -rf "$T"
case_end

case_begin "gating-artifact-stays-in-plans" "hooks/lib/temporary-migrations/control-dir-split/plan.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '# detail\n' > "$T/plans/${SID}-detail.md"
printf '# outline\n' > "$T/plans/${SID}-outline.md"
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate_all "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
if [ -f "$T/plans/${SID}-detail.md" ]; then
  pass "gating-artifact-stays-in-plans:detail"
else
  fail "gating-artifact-stays-in-plans:detail" "detail.md moved out of PLANS_DIR"
fi
if [ -f "$T/plans/${SID}-outline.md" ]; then
  pass "gating-artifact-stays-in-plans:outline"
else
  fail "gating-artifact-stays-in-plans:outline" "outline.md moved out of PLANS_DIR"
fi
rm -rf "$T"
case_end

case_begin "gating-lock-stays" "hooks/lib/temporary-migrations/control-dir-split/plan.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'lock-content\n' > "$T/plans/${SID}-supervisor-state.json.lock"
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate_all "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
if [ -f "$T/plans/${SID}-supervisor-state.json.lock" ]; then
  pass "gating-lock-stays"
else
  fail "gating-lock-stays" ".lock file should not be moved"
fi
rm -rf "$T"
case_end

case_begin "gating-tmp-stays" "hooks/lib/temporary-migrations/control-dir-split/plan.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'tmp-content\n' > "$T/plans/${SID}-x.tmp"
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate_all "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
if [ -f "$T/plans/${SID}-x.tmp" ]; then
  pass "gating-tmp-stays"
else
  fail "gating-tmp-stays" ".tmp file should not be moved"
fi
rm -rf "$T"
case_end

case_begin "tmp-cleanup-old-migrating" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
mkdir -p "$T/workflow-state/${SID}.control"
OLD_TMP="$T/workflow-state/${SID}.control/detail-plan-terminal.txt.migrating.12345.abc.tmp"
FRESH_TMP="$T/workflow-state/${SID}.control/detail-plan-terminal.txt.migrating.99999.xyz.tmp"
printf 'old\n' > "$OLD_TMP"
printf 'fresh\n' > "$FRESH_TMP"
age_files 90100 "$OLD_TMP"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
try {
  var m=require('$IDX_MOD');
  m.migrateAll({budgetMs:5000}).catch(function(){});
} catch(e){}
" 2>/dev/null
if [ ! -f "$OLD_TMP" ]; then
  pass "tmp-cleanup-old-migrating:old-removed"
else
  fail "tmp-cleanup-old-migrating:old-removed" "old .migrating tmp (>25h) should be removed"
fi
if [ -f "$FRESH_TMP" ]; then
  pass "tmp-cleanup-old-migrating:fresh-kept"
else
  fail "tmp-cleanup-old-migrating:fresh-kept" "fresh .migrating tmp should be kept"
fi
rm -rf "$T"
case_end

case_begin "no-reentry" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
SID2="bbccddee-2222-3333-4444-555566667777"
printf 'terminal1\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'terminal2\n' > "$T/plans/${SID2}-detail-plan-terminal.txt"
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt" "$T/plans/${SID2}-detail-plan-terminal.txt"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
RESULT=$(node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
try {
  var m=require('$IDX_MOD');
  var p1=m.migrateAll({budgetMs:5000});
  var p2=m.migrateAll({budgetMs:5000});
  Promise.all([p1,p2]).then(function(results){
    process.stdout.write('OK:'+String(results.length));
    process.exit(0);
  }).catch(function(e){
    process.stdout.write('THREW:'+String((e&&e.message)||e).split('\n')[0]);
    process.exit(0);
  });
} catch(e) {
  process.stdout.write('ERR:'+String(e.code||e.message).split('\n')[0]);
  process.exit(0);
}
" 2>/dev/null)
if printf '%s' "$RESULT" | grep -q '^ERR:'; then
  fail "no-reentry" "$RESULT"
else
  pass "no-reentry:concurrent-calls-resolve"
fi
rm -rf "$T"
case_end

echo ""
echo "gating: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
