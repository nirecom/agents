#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/conflict-race.sh
# Tests: hooks/lib/temporary-migrations/control-dir-split/apply.js, hooks/lib/temporary-migrations/control-dir-split/index.js
# Tags: TL2, scope:issue-specific, control-dir, migration, conflict
# TL3 gap: real concurrent writers; NTFS hardlink race semantics.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight category: migration.
# AMBIGUITY: race-dst seam name unspecified; see inline note in race-dst-wins case.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

IDX_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/temporary-migrations/control-dir-split/index.js")"
UUID="aabbccdd-1111-2222-3333-444455556666"

run_migrate_session() {
  local sid="$1" wf="$2" plans="$3"
  node -e "
process.env.WORKFLOW_STATE_DIR='$wf';
process.env.WORKFLOW_PLANS_DIR='$plans';
try {
  var m=require('$IDX_MOD');
  m.migrateSession('$sid').then(function(r){
    process.stdout.write('OK');
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

# Race scripts behind a start barrier: every process loads its code first,
# then spins until the parent creates the go-file (argv[2]; 10 s fallback).
# migrator.js prints "OK:<name>=<outcome>,..." so a case can tell a publish
# from a conflict.
write_race_scripts() { # <dir>
  cat > "$1/migrator.js" <<'JS'
const fs = require("fs");
let m;
try { m = require(process.argv[3]); } catch (e) { console.log("ERR:" + (e.code || e.message)); process.exit(0); }
const go = process.argv[2], until = Date.now() + 10000;
(function spin() { if (fs.existsSync(go) || Date.now() > until) return run(); setTimeout(spin, 1); })();
function run() {
  Promise.resolve().then(() => m.migrateSession(process.argv[4])).then((r) => {
    const rows = Array.isArray(r) ? r : [];
    console.log("OK:" + rows.map((x) => x && x.name + "=" + x.outcome).join(","));
  }).catch((e) => console.log("THREW:" + e.message));
}
JS
  cat > "$1/writer.js" <<'JS'
const fs = require("fs"), path = require("path");
const go = process.argv[2], dst = process.argv[3], until = Date.now() + 10000;
(function spin() { if (fs.existsSync(go) || Date.now() > until) return run(); setTimeout(spin, 1); })();
function run() {
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.writeFileSync(dst, process.argv[4]);
}
JS
}

case_begin "conflict-identical-content" "hooks/lib/temporary-migrations/control-dir-split/apply.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
mkdir -p "$T/workflow-state/${SID}.control"
printf 'same-content\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'same-content\n' > "$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
if printf '%s' "$RES" | grep -q '^ERR:'; then
  fail "conflict-identical-content" "$RES"
else
  if [ -f "$T/plans/${SID}-detail-plan-terminal.txt" ]; then
    fail "conflict-identical-content:src-not-removed" "identical src should be removed"
  else
    pass "conflict-identical-content:src-removed"
  fi
  if [ -f "$T/workflow-state/${SID}.control/detail-plan-terminal.txt" ]; then
    pass "conflict-identical-content:dst-present"
  else
    fail "conflict-identical-content:dst-missing" "dst should remain"
  fi
fi
rm -rf "$T"
case_end

case_begin "conflict-different-content" "hooks/lib/temporary-migrations/control-dir-split/apply.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
mkdir -p "$T/workflow-state/${SID}.control"
printf 'legacy-content\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'new-writer-content\n' > "$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
if printf '%s' "$RES" | grep -q '^ERR:'; then
  fail "conflict-different-content" "$RES"
else
  DST_CONTENT=$(cat "$T/workflow-state/${SID}.control/detail-plan-terminal.txt" 2>/dev/null || echo missing)
  if [ "$DST_CONTENT" = "new-writer-content" ]; then
    pass "conflict-different-content:dst-wins"
  else
    fail "conflict-different-content:dst-wins" "dst should keep new-writer-content, got: $DST_CONTENT"
  fi
  if [ -f "$T/plans/${SID}-detail-plan-terminal.txt" ]; then
    pass "conflict-different-content:src-kept"
  else
    fail "conflict-different-content:src-kept" "conflict src should be retained"
  fi
fi
rm -rf "$T"
case_end

case_begin "conflict-log-entry" "hooks/lib/temporary-migrations/control-dir-split/apply.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
mkdir -p "$T/workflow-state/${SID}.control"
printf 'src-content\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'dst-content\n' > "$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
LOG="$T/workflow-state/control-migration.log"
if [ -f "$LOG" ]; then
  pass "conflict-log-entry:log-exists"
  if grep -q "$SID" "$LOG" 2>/dev/null; then
    pass "conflict-log-entry:sid-in-log"
  else
    fail "conflict-log-entry:sid-in-log" "conflict log entry missing sid"
  fi
else
  fail "conflict-log-entry:log-missing" "control-migration.log not created for conflict"
fi
rm -rf "$T"
case_end

case_begin "race-dst-wins" "hooks/lib/temporary-migrations/control-dir-split/apply.js"
# Ambiguity: CONTROL_MIGRATION_FAULT=race-dst seam unspecified in plan (Step 3-8).
# Simulating race by pre-creating dst before migrateSession runs.
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
mkdir -p "$T/workflow-state/${SID}.control"
printf '1\n' > "$T/plans/${SID}-detail-plan-round-number.txt"
printf '3\n' > "$T/workflow-state/${SID}.control/detail-plan-round-number.txt"
RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
if printf '%s' "$RES" | grep -q '^ERR:'; then
  fail "race-dst-wins" "$RES"
else
  DST_ROUND=$(cat "$T/workflow-state/${SID}.control/detail-plan-round-number.txt" 2>/dev/null || echo missing)
  if [ "$DST_ROUND" = "3" ]; then
    pass "race-dst-wins:dst-value-preserved"
  else
    fail "race-dst-wins:dst-value-preserved" "expected 3, got: $DST_ROUND"
  fi
  if [ -f "$T/plans/${SID}-detail-plan-round-number.txt" ]; then
    pass "race-dst-wins:src-conflict-remains"
  else
    fail "race-dst-wins:src-conflict-remains" "conflict src should be retained when dst differs"
  fi
fi
rm -rf "$T"
case_end


# C8: real concurrency — 3 background processes against same source simultaneously
case_begin "concurrent-migrate-same-source" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"

CONTENT="concurrent-test-content"
printf '%s\n' "$CONTENT" > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '2\n' > "$T/plans/${SID}-detail-plan-round-number.txt"

# Start barrier: each migrator loads the module, then spins until the parent
# creates the go-file after ALL three are spawned, so they really race.
write_race_scripts "$T"
# One output file per migrator: concurrent `>>` into one file is not atomic on
# Windows (MSYS) and interleaves the outcome lines.
for i in 1 2 3; do
  WORKFLOW_STATE_DIR="$WF_NP" WORKFLOW_PLANS_DIR="$PLANS_NP" node "$T/migrator.js" "$(np "$T/go")" "$IDX_MOD" "$SID" > "$T/mig.$i.out" 2>/dev/null &
  eval "PID$i=\$!"
done
: > "$T/go"
wait $PID1
wait $PID2
wait $PID3
cat "$T"/mig.*.out > "$T/mig.out" 2>/dev/null

DST="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
SRC="$T/plans/${SID}-detail-plan-terminal.txt"
DST_R="$T/workflow-state/${SID}.control/detail-plan-round-number.txt"
SRC_R="$T/plans/${SID}-detail-plan-round-number.txt"

# Data-loss check: must never lose both src and dst
if [ ! -f "$DST" ] && [ ! -f "$SRC" ]; then
  fail "concurrent-migrate-same-source:no-data-loss" "BOTH src and dst missing — data lost!"
elif [ ! -f "$DST_R" ] && [ ! -f "$SRC_R" ]; then
  fail "concurrent-migrate-same-source:no-data-loss-round" "BOTH round src and dst missing — data lost!"
else
  pass "concurrent-migrate-same-source:no-data-loss"
fi

if [ -f "$DST" ]; then
  DST_CONTENT=$(cat "$DST" 2>/dev/null || echo MISSING)
  if [ "$DST_CONTENT" = "${CONTENT}" ]; then
    pass "concurrent-migrate-same-source:dst-complete-content"
  else
    fail "concurrent-migrate-same-source:dst-complete-content" "dst has unexpected content: $(printf '%q' "$DST_CONTENT")"
  fi
  # Every racer publishes the same bytes, so a loser sees EEXIST with an
  # identical dst and must unlink src (Step 3-2-4): no src may survive.
  if [ ! -f "$SRC" ]; then
    pass "concurrent-migrate-same-source:src-removed"
  else
    fail "concurrent-migrate-same-source:src-removed" "identical-content race left the legacy source behind"
  fi
  if [ "$(cat "$DST_R" 2>/dev/null || echo MISSING)" = "2" ]; then
    pass "concurrent-migrate-same-source:round-dst-complete"
  else
    fail "concurrent-migrate-same-source:round-dst-complete" "round-number dst missing or partial"
  fi
  if [ -f "$SRC_R" ]; then
    fail "concurrent-migrate-same-source:round-src-removed" "round-number legacy source left behind"
  else
    pass "concurrent-migrate-same-source:round-src-removed"
  fi
  if [ -z "$(find "$T/workflow-state/${SID}.control" -name '*.migrating.*' 2>/dev/null)" ]; then
    pass "concurrent-migrate-same-source:no-tmp-residue"
  else
    fail "concurrent-migrate-same-source:no-tmp-residue" "staging tmp left in the control dir"
  fi
else
  # dst not created: implementation absent or all 3 processes failed
  if [ -f "$SRC" ]; then
    SRC_CONTENT=$(cat "$SRC" 2>/dev/null || echo MISSING)
    if [ "$SRC_CONTENT" = "${CONTENT}" ]; then
      fail "concurrent-migrate-same-source" "implementation missing: dst not created after 3 concurrent migrations"
    else
      fail "concurrent-migrate-same-source:src-corrupt" "source corrupted with no dst: $SRC_CONTENT"
    fi
  fi
fi
rm -rf "$T"
case_end

# C8: concurrent conflicting content. Two new writers (different content) and
# two migrations race on the same destination, released together by a start
# barrier. Plan semantics (Step 3-2): publish is exclusive (link / wx), so a
# migration can never overwrite a writer; dst ends as one writer's full value;
# the legacy source is either gone (migration published first, then a writer
# overwrote it) or kept byte-identical as a conflict, logged. Repeated to
# widen the interleavings.
case_begin "concurrent-conflicting-writers" "hooks/lib/temporary-migrations/control-dir-split/apply.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
write_race_scripts "$T"
CTL="$T/workflow-state/${SID}.control"
DST="$CTL/detail-plan-round-number.txt"
SRC="$T/plans/${SID}-detail-plan-round-number.txt"
IMPL_OK=1
for iter in 1 2 3 4 5; do
  rm -rf "$CTL" "$T/go" "$T/workflow-state/control-migration.log" "$T/mig.out" "$T/mig.1.out" "$T/mig.3.out"
  printf '1\n' > "$SRC"
  cp "$SRC" "$T/legacy.orig"
  # Per-migrator output files (see concurrent-migrate-same-source), joined after the wait.
  WORKFLOW_STATE_DIR="$WF_NP" WORKFLOW_PLANS_DIR="$PLANS_NP" node "$T/migrator.js" "$(np "$T/go")" "$IDX_MOD" "$SID" > "$T/mig.1.out" 2>/dev/null &
  P1=$!
  node "$T/writer.js" "$(np "$T/go")" "$(np "$DST")" "writer-A-3" 2>/dev/null &
  P2=$!
  WORKFLOW_STATE_DIR="$WF_NP" WORKFLOW_PLANS_DIR="$PLANS_NP" node "$T/migrator.js" "$(np "$T/go")" "$IDX_MOD" "$SID" > "$T/mig.3.out" 2>/dev/null &
  P3=$!
  node "$T/writer.js" "$(np "$T/go")" "$(np "$DST")" "writer-B-4" 2>/dev/null &
  P4=$!
  : > "$T/go"
  wait $P1
  wait $P2
  wait $P3
  wait $P4
  cat "$T/mig.1.out" "$T/mig.3.out" > "$T/mig.out" 2>/dev/null
  if grep -q '^ERR:' "$T/mig.out" 2>/dev/null; then
    fail "concurrent-conflicting-writers" "migrateSession unavailable: $(head -1 "$T/mig.out") (implementation missing)"
    IMPL_OK=0
    break
  fi
  GOT="$(cat "$DST" 2>/dev/null || echo MISSING)"
  DST_IS_WRITER=0
  case "$GOT" in
    writer-A-3|writer-B-4) DST_IS_WRITER=1; pass "concurrent-conflicting-writers:$iter:dst-is-a-whole-writer-value" ;;
    *) fail "concurrent-conflicting-writers:$iter:dst-is-a-whole-writer-value" "dst=$(printf '%q' "$GOT") (legacy won, or partial)" ;;
  esac
  if [ ! -f "$SRC" ]; then
    # Source consumed. Passes only when (a) dst holds one writer's exact bytes
    # and (b) the legacy bytes were preserved by a real publish (outcome
    # "migrated"/"identical") that the writer then superseded -- never
    # dropped as a "conflict" or "failed" with nothing kept (Step 3-2-4).
    if [ "$DST_IS_WRITER" -eq 1 ] \
       && grep -Eq 'detail-plan-round-number\.txt=(migrated|identical)' "$T/mig.out" \
       && ! grep -Eq 'detail-plan-round-number\.txt=(conflict|failed)' "$T/mig.out"; then
      pass "concurrent-conflicting-writers:$iter:src-consumed-by-publish"
    else
      fail "concurrent-conflicting-writers:$iter:src-consumed-by-publish" "legacy source gone without a clean publish (data loss): dst=$(printf '%q' "$GOT") outcomes=$(tr '\n' ' ' < "$T/mig.out")"
    fi
  else
    if cmp -s "$T/legacy.orig" "$SRC"; then pass "concurrent-conflicting-writers:$iter:conflict-src-byte-identical"
    else fail "concurrent-conflicting-writers:$iter:conflict-src-byte-identical" "kept source was altered"; fi
    if grep -q "$SID" "$T/workflow-state/control-migration.log" 2>/dev/null; then
      pass "concurrent-conflicting-writers:$iter:conflict-logged"
    else
      fail "concurrent-conflicting-writers:$iter:conflict-logged" "source kept as conflict but no control-migration.log line"
    fi
  fi
  if [ -z "$(find "$CTL" -name '*.migrating.*' 2>/dev/null)" ]; then
    pass "concurrent-conflicting-writers:$iter:no-tmp-residue"
  else
    fail "concurrent-conflicting-writers:$iter:no-tmp-residue" "staging tmp left in the control dir"
  fi
done
rm -rf "$T"
case_end

echo ""
echo "conflict-race: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
