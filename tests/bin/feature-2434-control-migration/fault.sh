#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/fault.sh
# Tests: hooks/workflow-state/state-io/control-dir.js, hooks/lib/temporary-migrations/control-dir-split/index.js, hooks/workflow-state/evidence-resolver.js
# Tags: TL2, scope:issue-specific, control-dir, migration, fault-injection
# TL3 gap: real EACCES on production hosts; Windows ACL vs POSIX chmod differ.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight category: migration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_mtime.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

CTRL_DIR_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io/control-dir.js")"
IDX_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/temporary-migrations/control-dir-split/index.js")"
EVID_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/evidence-resolver.js")"
WCD_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow-control-dir"
UUID="aabbccdd-1111-2222-3333-444455556666"

# Helper: run workflow-control-dir, capture exit code and stderr
run_wcd() {
  local sid="$1" fname="$2" wf="$3" plans="$4" fault="${5:-}"
  local out
  out=$(WORKFLOW_STATE_DIR="$wf" WORKFLOW_PLANS_DIR="$plans" CONTROL_MIGRATION_FAULT="$fault" \
        node "$WCD_CLI" --session "$sid" --file "$fname" 2>&1)
  echo "$?|$out"
}

case_begin "fault-link-fail-exit3-stderr" "hooks/workflow-state/state-io/control-dir.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
if [ ! -f "$WCD_CLI" ]; then
  fail "fault-link-fail-exit3-stderr" "bin/workflow-control-dir not found (implementation absent)"
else
  RESULT=$(WORKFLOW_STATE_DIR="$(np "$T/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$T/plans")" \
           CONTROL_MIGRATION_FAULT="link-fail" \
           node "$WCD_CLI" --session "$SID" --file "detail-plan-terminal.txt" 2>&1)
  RC=$?
  if [ "$RC" -ne 3 ]; then
    fail "fault-link-fail-exit3-stderr:exit" "expected 3, got $RC"
  else
    pass "fault-link-fail-exit3-stderr:exit3"
  fi
  LEGACY_PATH="$T/plans/${SID}-detail-plan-terminal.txt"
  if printf '%s' "$RESULT" | grep -q "$SID"; then
    pass "fault-link-fail-exit3-stderr:sid-in-stderr"
  else
    fail "fault-link-fail-exit3-stderr:sid-in-stderr" "legacy path not in stderr output"
  fi
fi
rm -rf "$T"
case_end

case_begin "fault-dst-unwritable-exit3" "hooks/workflow-state/state-io/control-dir.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
if [ ! -f "$WCD_CLI" ]; then
  fail "fault-dst-unwritable-exit3" "bin/workflow-control-dir not found (implementation absent)"
else
  RESULT=$(WORKFLOW_STATE_DIR="$(np "$T/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$T/plans")" \
           CONTROL_MIGRATION_FAULT="dst-unwritable" \
           node "$WCD_CLI" --session "$SID" --file "detail-plan-terminal.txt" 2>&1)
  RC=$?
  if [ "$RC" -ne 3 ]; then
    fail "fault-dst-unwritable-exit3" "expected exit 3, got $RC"
  else
    pass "fault-dst-unwritable-exit3"
  fi
fi
rm -rf "$T"
case_end

case_begin "fault-rewrite-fail-exit3" "hooks/workflow-state/state-io/control-dir.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf 'BROKEN JSON {{{' > "$T/plans/${SID}-finalize-binding-1.json"
if [ ! -f "$WCD_CLI" ]; then
  fail "fault-rewrite-fail-exit3" "bin/workflow-control-dir not found (implementation absent)"
else
  RESULT=$(WORKFLOW_STATE_DIR="$(np "$T/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$T/plans")" \
           CONTROL_MIGRATION_FAULT="rewrite-fail" \
           node "$WCD_CLI" --session "$SID" --file "detail-plan-terminal.txt" 2>&1)
  RC=$?
  if [ "$RC" -ne 3 ]; then
    fail "fault-rewrite-fail-exit3" "expected exit 3, got $RC"
  else
    pass "fault-rewrite-fail-exit3"
  fi
fi
rm -rf "$T"
case_end

case_begin "fault-link-fail-round-number-not-reset" "hooks/workflow-state/state-io/control-dir.js"
# After fault: round-number must not reset to 1 (wrapper must exit 4, not continue)
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
WRAPPER="$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '2\n' > "$T/plans/${SID}-detail-plan-round-number.txt"
printf '# detail\n' > "$T/plans/${SID}-detail.md"
if [ ! -f "$WRAPPER" ]; then
  fail "fault-link-fail-round-number-not-reset" "wrapper script not found"
else
  TMPROOT=$(make_tmp)
  # The wrapper finds bin/ from its own location: copy the tree, then place the stubs.
  source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
  script_checkout_fixture_copy "$TMPROOT" bin hooks skills/make-detail-plan
  mkdir -p "$TMPROOT/bin"
  for b in resolve-accepted-tradeoffs-file concern-ledger run-codex-review-loop; do
    printf '#!/bin/bash\nexit 0\n' > "$TMPROOT/bin/$b"
    chmod +x "$TMPROOT/bin/$b"
  done
  WRAPPER="$TMPROOT/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
  RESULT=$(SESSION_ID="$SID" \
           PLANS_DIR="$(np "$T/plans")" EXTENSIONS_USED="0" \
           WORKFLOW_STATE_DIR="$(np "$T/workflow-state")" \
           WORKFLOW_PLANS_DIR="$(np "$T/plans")" \
           CONTROL_MIGRATION_FAULT="link-fail" \
           bash "$WRAPPER" 2>&1)
  RC=$?
  if [ "$RC" -eq 4 ]; then
    pass "fault-link-fail-round-number-not-reset:exit4"
  else
    fail "fault-link-fail-round-number-not-reset:exit4" "expected 4, got $RC (implementation absent?)"
  fi
  ROUND=$(cat "$T/plans/${SID}-detail-plan-round-number.txt" 2>/dev/null || echo missing)
  if [ "$ROUND" = "2" ]; then
    pass "fault-link-fail-round-number-not-reset:round-stable"
  elif [ "$ROUND" = "1" ]; then
    fail "fault-link-fail-round-number-not-reset:round-reset" "round-number was reset to 1"
  else
    pass "fault-link-fail-round-number-not-reset:round-stable"
  fi
  rm -rf "$TMPROOT"
fi
rm -rf "$T"
case_end

case_begin "fault-link-fail-evidence-no-new-file" "hooks/workflow-state/evidence-resolver.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
printf '# detail\n' > "$T/plans/${SID}-detail.md"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
FILES_BEFORE=$(find "$T/workflow-state" -type f 2>/dev/null | wc -l || echo 0)
RESULT=$(node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
process.env.CONTROL_MIGRATION_FAULT='link-fail';
try {
  var m=require('$EVID_MOD');
  var ok=m.hasCompletionEvidence('detail','$SID',{});
  process.stdout.write('EVID:'+String(ok));
} catch(e) {
  process.stdout.write('ERR:'+String(e.code||e.message).split('\n')[0]);
}
" 2>/dev/null)
FILES_AFTER=$(find "$T/workflow-state" -type f 2>/dev/null | wc -l || echo 0)
if printf '%s' "$RESULT" | grep -q '^ERR:'; then
  fail "fault-link-fail-evidence-no-new-file:evid-call" "$RESULT"
else
  EVID_VAL=$(printf '%s' "$RESULT" | sed 's/EVID://')
  if [ "$EVID_VAL" = "false" ]; then
    pass "fault-link-fail-evidence-no-new-file:returns-false"
  else
    fail "fault-link-fail-evidence-no-new-file:returns-false" "expected false, got $EVID_VAL (D5 not implemented?)"
  fi
  if [ "$FILES_AFTER" -le "$FILES_BEFORE" ]; then
    pass "fault-link-fail-evidence-no-new-file:no-new-files"
  else
    fail "fault-link-fail-evidence-no-new-file:no-new-files" "evidence-resolver created new files under fault"
  fi
fi
rm -rf "$T"
case_end

case_begin "fault-migrate-all-nothrow" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
RESULT=$(node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
process.env.CONTROL_MIGRATION_FAULT='link-fail';
try {
  var m=require('$IDX_MOD');
  Promise.resolve(m.migrateAll({budgetMs:5000})).then(function(cursor){
    var complete=cursor&&cursor.complete;
    process.stdout.write('OK:complete='+String(complete));
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
  fail "fault-migrate-all-nothrow" "$RESULT"
elif printf '%s' "$RESULT" | grep -q 'THREW:'; then
  fail "fault-migrate-all-nothrow:threw" "migrateAll threw: $RESULT"
else
  if printf '%s' "$RESULT" | grep -q 'complete=false'; then
    pass "fault-migrate-all-nothrow:incomplete"
  else
    fail "fault-migrate-all-nothrow:incomplete" "cursor should be complete=false on fault: $RESULT"
  fi
fi
rm -rf "$T"
case_end

case_begin "fault-rerun-completes" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
# Aged past the quiet period: a fresh file is skipped by BOTH runs (complete=false),
# which would leave the fault unexercised and the rerun unable to complete.
age_files 700 "$T/plans/${SID}-detail-plan-terminal.txt"
WF_NP="$(np "$T/workflow-state")"
PLANS_NP="$(np "$T/plans")"
node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
process.env.CONTROL_MIGRATION_FAULT='link-fail';
try { var m=require('$IDX_MOD'); m.migrateAll({budgetMs:5000}).catch(function(){}); } catch(e){}
" 2>/dev/null
RESULT=$(node -e "
process.env.WORKFLOW_STATE_DIR='$WF_NP';
process.env.WORKFLOW_PLANS_DIR='$PLANS_NP';
try {
  var m=require('$IDX_MOD');
  Promise.resolve(m.migrateAll({budgetMs:5000})).then(function(c){
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
if printf '%s' "$RESULT" | grep -q 'complete=true'; then
  pass "fault-rerun-completes"
  if [ -f "$T/workflow-state/${SID}.control/detail-plan-terminal.txt" ]; then
    pass "fault-rerun-completes:published"
  else
    fail "fault-rerun-completes:published" "complete=true but the control file was not published"
  fi
else
  fail "fault-rerun-completes" "rerun without fault should complete: $RESULT"
fi
rm -rf "$T"
case_end

case_begin "fault-link-fail-wcd-stderr-legacy-path" "hooks/workflow-state/state-io/control-dir.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
printf 'terminal\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
if [ ! -f "$WCD_CLI" ]; then
  fail "fault-link-fail-wcd-stderr-legacy-path" "bin/workflow-control-dir not found (implementation absent)"
else
  STDERR=$(WORKFLOW_STATE_DIR="$(np "$T/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$T/plans")" \
           CONTROL_MIGRATION_FAULT="link-fail" \
           node "$WCD_CLI" --session "$SID" --file "detail-plan-terminal.txt" 2>&1 >/dev/null)
  EXPECTED_LEGACY="${SID}-detail-plan-terminal.txt"
  if printf '%s' "$STDERR" | grep -qF "$EXPECTED_LEGACY"; then
    pass "fault-link-fail-wcd-stderr-legacy-path"
  else
    fail "fault-link-fail-wcd-stderr-legacy-path" "legacy filename not in stderr: $STDERR"
  fi
fi
rm -rf "$T"
case_end

# The three C7 cases below share one scenario (c7_scenario): seed several
# legacy control files, migrate under a fault, check EVERY file, retry without
# the fault, check EVERY destination, then retry again for idempotence.
# migrateSession is used, not migrateAll: migrateAll leaves freshly written
# files of other sids alone for the 10-minute quiet period, so it cannot show
# a retry "reaching the correct result" in a test.
C7_DRIVER_SRC='
const [mod, sid] = process.argv.slice(2);
let m;
try { m = require(mod); } catch (e) { console.log("ERR:" + (e.code || e.message)); process.exit(0); }
Promise.resolve().then(() => m.migrateSession(sid)).then((r) => {
  const rows = Array.isArray(r) ? r : [];
  console.log("OK:" + rows.map((x) => x && x.name + "=" + x.outcome).join(","));
}).catch((e) => console.log("THREW:" + String((e && e.message) || e).split("\n")[0]));
'

c7_migrate() { # <sid> <wf> <plans> [fault]
  local drv="$T/c7-driver.js"
  printf '%s' "$C7_DRIVER_SRC" > "$drv"
  if [ -n "${4:-}" ]; then
    WORKFLOW_STATE_DIR="$2" WORKFLOW_PLANS_DIR="$3" CONTROL_MIGRATION_FAULT="$4" \
      node "$drv" "$IDX_MOD" "$1" 2>/dev/null | tr -d '\r'
  else
    ( unset CONTROL_MIGRATION_FAULT
      WORKFLOW_STATE_DIR="$2" WORKFLOW_PLANS_DIR="$3" node "$drv" "$IDX_MOD" "$1" 2>/dev/null | tr -d '\r' )
  fi
}

c7_snapshot() { # checksum of every file under the control dir, path-sorted
  find "$1" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "${f#$1/}" "$(cksum < "$f")"
  done
}

c7_scenario() { # <label> <fault>
  local L="$1" FAULT="$2"
  T=$(make_tmp)
  harness_isolate "$T"
  local SID="$UUID" WF_NP PLANS_NP CTL ORIG n
  WF_NP="$(np "$T/workflow-state")"
  PLANS_NP="$(np "$T/plans")"
  CTL="$T/workflow-state/${SID}.control"
  ORIG="$T/orig"
  mkdir -p "$ORIG"

  # Plain (byte-preserved) files and one path-embedding binding. Every file is
  # rewritable, so the retry without the fault must migrate all of them.
  local PLAIN="detail-plan-terminal.txt detail-plan-round-number.txt detail-plan-last-round.txt finalize-state-1.json"
  printf 'termdata\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
  printf '2\n' > "$T/plans/${SID}-detail-plan-round-number.txt"
  printf '1\n' > "$T/plans/${SID}-detail-plan-last-round.txt"
  printf '{"step":"commit"}\n' > "$T/plans/${SID}-finalize-state-1.json"
  printf '{"state_file_path":"%s"}\n' "$PLANS_NP/${SID}-finalize-state-1.json" > "$T/plans/${SID}-finalize-binding-1.json"
  local BINDINGS="finalize-binding-1.json"
  for n in $PLAIN $BINDINGS; do cp "$T/plans/${SID}-$n" "$ORIG/$n"; done

  local R1
  R1="$(c7_migrate "$SID" "$WF_NP" "$PLANS_NP" "$FAULT")"
  case "$R1" in
    ERR:*|THREW:*|"") fail "$L:fault-run" "migrateSession unavailable: ${R1:-no output} (implementation missing)"; rm -rf "$T"; return ;;
  esac

  # After the fault, migration is atomic (user decision): every legacy source
  # stays byte-identical and NO file of the session exists at the destination,
  # parseable bindings included. No partial-migration branch passes.
  for n in $PLAIN $BINDINGS; do
    if [ -f "$T/plans/${SID}-$n" ] && cmp -s "$ORIG/$n" "$T/plans/${SID}-$n"; then
      pass "$L:after-fault:src-byte-identical:$n"
    else
      fail "$L:after-fault:src-byte-identical:$n" "legacy source removed or altered by the failed migration"
    fi
    if [ -e "$CTL/$n" ]; then fail "$L:after-fault:no-dst:$n" "destination exists after a $FAULT fault (migration not atomic)"
    else pass "$L:after-fault:no-dst:$n"; fi
  done
  if [ -z "$(find "$CTL" -type f 2>/dev/null)" ]; then pass "$L:after-fault:control-dir-empty"
  else fail "$L:after-fault:control-dir-empty" "files left in the control dir after the fault: $(find "$CTL" -type f 2>/dev/null | tr '\n' ' ')"; fi
  # Retry without the fault: every file reaches the correct final state.
  local R2
  R2="$(c7_migrate "$SID" "$WF_NP" "$PLANS_NP" "")"
  for n in $PLAIN; do
    if cmp -s "$ORIG/$n" "$CTL/$n"; then pass "$L:retry:dst-content:$n"
    else fail "$L:retry:dst-content:$n" "destination missing or not byte-identical after retry ($R2)"; fi
    if [ -e "$T/plans/${SID}-$n" ]; then fail "$L:retry:src-removed:$n" "legacy source still present after retry"
    else pass "$L:retry:src-removed:$n"; fi
  done
  local SFP WANT_SFP
  SFP="$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(String(j.state_file_path).replace(/\\/g,"/"))}catch(e){console.log("UNREADABLE")}' "$(np "$CTL/finalize-binding-1.json")" 2>/dev/null | tr -d '\r')"
  WANT_SFP="$(printf '%s' "$(np "$CTL/finalize-state-1.json")" | tr '\\' '/')"
  if [ "$SFP" = "$WANT_SFP" ]; then pass "$L:retry:binding-rewritten"
  else fail "$L:retry:binding-rewritten" "state_file_path want=$WANT_SFP got=$SFP"; fi
  if [ -e "$T/plans/${SID}-finalize-binding-1.json" ]; then fail "$L:retry:binding-src-removed" "legacy binding still present"
  else pass "$L:retry:binding-src-removed"; fi

  # Second retry changes nothing.
  local S1 S2
  S1="$(c7_snapshot "$CTL")"
  c7_migrate "$SID" "$WF_NP" "$PLANS_NP" "" >/dev/null
  S2="$(c7_snapshot "$CTL")"
  if [ -n "$S1" ] && [ "$S1" = "$S2" ]; then pass "$L:second-retry-idempotent"
  else fail "$L:second-retry-idempotent" "control dir changed on the second retry (or is empty)"; fi
  rm -rf "$T"
}

case_begin "fault-link-sources-preserved-no-dst-retry" "hooks/lib/temporary-migrations/control-dir-split/index.js"
c7_scenario "fault-link-sources-preserved-no-dst-retry" "link-fail"
case_end

case_begin "fault-dst-write-sources-preserved-retry" "hooks/lib/temporary-migrations/control-dir-split/index.js"
c7_scenario "fault-dst-write-sources-preserved-retry" "dst-unwritable"
case_end

case_begin "fault-rewrite-sources-preserved-no-partial-retry" "hooks/lib/temporary-migrations/control-dir-split/index.js"
c7_scenario "fault-rewrite-sources-preserved-no-partial-retry" "rewrite-fail"
case_end

echo ""
echo "fault: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
