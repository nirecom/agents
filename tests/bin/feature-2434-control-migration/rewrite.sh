#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/rewrite.sh
# Tests: hooks/lib/temporary-migrations/control-dir-split/rewrite.js, hooks/lib/temporary-migrations/control-dir-split/cursor.js, hooks/lib/temporary-migrations/control-dir-split/index.js
# Tags: TL2, scope:issue-specific, control-dir, migration, rewrite, cursor
# TL3 gap: mtime granularity on NTFS (100ns) vs APFS vs ext4; real NFS mtimes.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight category: migration.
# AMBIGUITY: CONTROL_MIGRATION_TRACE=1 output format unspecified; assumes stderr line
# containing "readdir" — flag for implementor review.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_mtime.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

IDX_MOD="$(np "$AGENTS_DIR/hooks/lib/temporary-migrations/control-dir-split/index.js")"
UUID="aabbccdd-1111-2222-3333-444455556666"

run_migrate() {
  local sid="$1" wf="$2" plans="$3"
  node -e "
process.env.WORKFLOW_STATE_DIR='$wf';
process.env.WORKFLOW_PLANS_DIR='$plans';
try {
  var m=require('$IDX_MOD');
  m.migrateSession('$sid').then(function(){
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

case_begin "rewrite-binding-state-file-path" "hooks/lib/temporary-migrations/control-dir-split/rewrite.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
OLD_PATH="$T/plans/${SID}-finalize-state-1.json"
EXPECTED_NEW="$T/workflow-state/${SID}.control/finalize-state-1.json"
printf '{"state_file_path":"%s","other":"val"}\n' "$OLD_PATH" > "$T/plans/${SID}-finalize-binding-1.json"
printf '{"status":"ok"}\n' > "$T/plans/${SID}-finalize-state-1.json"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST_BINDING="$T/workflow-state/${SID}.control/finalize-binding-1.json"
if [ -f "$DST_BINDING" ]; then
  STATE_PATH=$(node -e "
try {
  var o=JSON.parse(require('fs').readFileSync('$(np "$DST_BINDING")','utf8'));
  process.stdout.write(String(o.state_file_path||'missing'));
} catch(e) { process.stdout.write('ERR'); }
" 2>/dev/null)
  if printf '%s' "$STATE_PATH" | grep -q "${SID}.control/finalize-state"; then
    pass "rewrite-binding-state-file-path"
  else
    fail "rewrite-binding-state-file-path" "state_file_path not rewritten: $STATE_PATH"
  fi
else
  fail "rewrite-binding-state-file-path" "binding dst missing"
fi
rm -rf "$T"
case_end

case_begin "rewrite-handoff-pointer" "hooks/lib/temporary-migrations/control-dir-split/rewrite.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
OLD_PTR="$T/plans/${SID}-handoff.md"
printf '# Handoff\n--pointer %s\n' "$OLD_PTR" > "$T/plans/${SID}-handoff.md"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST_HANDOFF="$T/workflow-state/${SID}.control/handoff.md"
if [ -f "$DST_HANDOFF" ]; then
  CONTENT=$(cat "$DST_HANDOFF" 2>/dev/null || echo missing)
  if printf '%s' "$CONTENT" | grep -q "${SID}.control/handoff"; then
    pass "rewrite-handoff-pointer"
  else
    fail "rewrite-handoff-pointer" "--pointer not rewritten in handoff.md: $CONTENT"
  fi
else
  fail "rewrite-handoff-pointer" "handoff.md dst missing"
fi
rm -rf "$T"
case_end

case_begin "rewrite-supervisor-state-values" "hooks/lib/temporary-migrations/control-dir-split/rewrite.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
OLD_PATH="$T/plans/${SID}-some-control.txt"
printf '{"session_id":"%s","some_path":"%s","name":"ok"}\n' "$SID" "$OLD_PATH" > "$T/plans/${SID}-supervisor-state.json"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${SID}.control/supervisor-state.json"
if [ -f "$DST" ]; then
  SOME_PATH=$(node -e "
try {
  var o=JSON.parse(require('fs').readFileSync('$(np "$DST")','utf8'));
  process.stdout.write(String(o.some_path||'missing'));
} catch(e) { process.stdout.write('ERR'); }
" 2>/dev/null)
  if printf '%s' "$SOME_PATH" | grep -q "${SID}.control"; then
    pass "rewrite-supervisor-state-values"
  else
    fail "rewrite-supervisor-state-values" "path not rewritten: $SOME_PATH"
  fi
else
  fail "rewrite-supervisor-state-values" "supervisor-state.json dst missing"
fi
rm -rf "$T"
case_end

case_begin "rewrite-worker-json-values" "hooks/lib/temporary-migrations/control-dir-split/rewrite.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
OLD="$T/plans/${SID}-finalize-state-1.json"
printf '{"session_id":"%s","state_file_path":"%s"}\n' "$SID" "$OLD" > "$T/plans/${SID}-worker-x-1.json"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
run_migrate "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${SID}.control/worker-x-1.json"
if [ -f "$DST" ]; then
  SFPATH=$(node -e "
try {
  var o=JSON.parse(require('fs').readFileSync('$(np "$DST")','utf8'));
  process.stdout.write(String(o.state_file_path||'missing'));
} catch(e) { process.stdout.write('ERR'); }
" 2>/dev/null)
  if printf '%s' "$SFPATH" | grep -q "${SID}.control"; then
    pass "rewrite-worker-json-values"
  else
    fail "rewrite-worker-json-values" "state_file_path not rewritten: $SFPATH"
  fi
else
  fail "rewrite-worker-json-values" "worker-x-1.json dst missing"
fi
rm -rf "$T"
case_end

case_begin "cursor-quiet-period-incomplete" "hooks/lib/temporary-migrations/control-dir-split/cursor.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
SID2="bbccddee-2222-3333-4444-555566667777"
printf 'terminal\n' > "$T/plans/${SID2}-detail-plan-terminal.txt"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
RESULT=$(node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
try {
  var m=require('$IDX_MOD');
  Promise.resolve(m.migrateAll({budgetMs:5000,excludeSid:'$UUID'})).then(function(c){
    process.stdout.write('OK:complete='+String(c&&c.complete));
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
if printf '%s' "$RESULT" | grep -qE '^ERR:|^THREW:'; then
  fail "cursor-quiet-period-incomplete" "$RESULT"
elif printf '%s' "$RESULT" | grep -q 'complete=false'; then
  pass "cursor-quiet-period-incomplete:complete-false"
else
  fail "cursor-quiet-period-incomplete:complete-false" "recent sid should make complete=false: $RESULT"
fi
rm -rf "$T"
case_end

case_begin "cursor-budget-zero-cutoff" "hooks/lib/temporary-migrations/control-dir-split/cursor.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
RESULT=$(node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
try {
  var m=require('$IDX_MOD');
  Promise.resolve(m.migrateAll({budgetMs:0})).then(function(c){
    process.stdout.write('OK:complete='+String(c&&c.complete));
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
if printf '%s' "$RESULT" | grep -qE '^ERR:|^THREW:'; then
  fail "cursor-budget-zero-cutoff" "$RESULT"
elif printf '%s' "$RESULT" | grep -q 'complete=false'; then
  pass "cursor-budget-zero-cutoff"
else
  fail "cursor-budget-zero-cutoff" "budgetMs=0 should produce complete=false: $RESULT"
fi
rm -rf "$T"
case_end

case_begin "cursor-no-readdir-on-complete" "hooks/lib/temporary-migrations/control-dir-split/cursor.js"
T=$(make_tmp)
harness_isolate "$T"
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
TRACE=$(CONTROL_MIGRATION_TRACE=1 node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
process.env.CONTROL_MIGRATION_TRACE='1';
try {
  var m=require('$IDX_MOD');
  m.migrateAll({budgetMs:5000}).catch(function(){});
} catch(e){}
" 2>&1)
if printf '%s' "$TRACE" | grep -qi 'readdir'; then
  fail "cursor-no-readdir-on-complete" "readdir called on second migrateAll with no PLANS change"
elif printf '%s' "$TRACE" | grep -qE '^ERR:|MODULE'; then
  fail "cursor-no-readdir-on-complete" "module missing: $TRACE"
else
  pass "cursor-no-readdir-on-complete"
fi
rm -rf "$T"
case_end

case_begin "rewrite-table-must-and-must-not" "hooks/lib/temporary-migrations/control-dir-split/rewrite.js"
T=$(make_tmp)
harness_isolate "$T"
RW_MOD="$(np "$AGENTS_DIR/hooks/lib/temporary-migrations/control-dir-split/rewrite.js")"
RW_CTL="$(np "$T/workflow-state/${UUID}.control")"
RW_OTHER="bbccddee-2222-3333-4444-555566667777"
# The legacy path is built inside node so no backslash crosses a shell quoting layer.
RW_JS='
const a = process.argv.slice(1);
const mod = a[0], sid = a[1], other = a[2], ctl = a[3], want = a[4], form = a[5], who = a[6], rest = a[7];
const sep = { fwd: "/", back: "\\", json: "\\\\" }[form];
if (!sep || !/^(keep|move)$/.test(want)) { process.stdout.write("bad-row:" + want + "/" + form); process.exit(0); }
const legacy = "C:/work/plans/" + (who === "other" ? other : sid) + "-" + rest;
const input = "ptr " + legacy.split("/").join(sep) + " end";
const expected = want === "move" ? "ptr " + ctl + "/" + rest + " end" : input;
let got;
try {
  got = require(mod).rewriteContent(Buffer.from(input), { sid: sid, ctlDir: ctl, name: "handoff.md" }).toString("utf8");
} catch (e) { got = "THREW:" + String((e && e.message) || e); }
process.stdout.write(got === expected ? "OK" : "want=" + JSON.stringify(expected) + " got=" + JSON.stringify(got));
'
while IFS='|' read -r rw_label rw_want rw_form rw_who rw_rest; do
  [[ -z "$rw_label" || "$rw_label" =~ ^[[:space:]]*# ]] && continue
  rw_label="${rw_label//[[:space:]]/}"
  rw_want="${rw_want//[[:space:]]/}"
  rw_form="${rw_form//[[:space:]]/}"
  rw_who="${rw_who//[[:space:]]/}"
  rw_rest="${rw_rest//[[:space:]]/}"
  RW_GOT=$(node -e "$RW_JS" "$RW_MOD" "$UUID" "$RW_OTHER" "$RW_CTL" "$rw_want" "$rw_form" "$rw_who" "$rw_rest" 2>/dev/null)
  if [ "$RW_GOT" = "OK" ]; then
    pass "rewrite-table:$rw_label"
  else
    fail "rewrite-table:$rw_label" "$rw_want expected: ${RW_GOT:-no output}"
  fi
done <<'TABLE'
# label              | want | form | sid   | name after "<sid>-"
artifact-detail      | keep | fwd  | own   | detail.md
artifact-intent      | keep | fwd  | own   | intent.md
other-session        | keep | fwd  | other | detail-plan-terminal.txt
never-move-lock      | keep | fwd  | own   | x.lock
never-move-tmp       | keep | fwd  | own   | x.tmp
control-fwd          | move | fwd  | own   | detail-plan-terminal.txt
control-backslash    | move | back | own   | detail-plan-terminal.txt
control-json-escaped | move | json | own   | detail-plan-terminal.txt
control-trailing-dot | move | fwd  | own   | detail-plan-terminal.txt.
TABLE
rm -rf "$T"
case_end

echo ""
echo "rewrite: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
