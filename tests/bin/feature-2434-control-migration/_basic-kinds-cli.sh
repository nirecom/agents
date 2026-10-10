# tests/bin/feature-2434-control-migration/_basic-kinds-cli.sh
# Sourced by basic.sh (not a standalone part): the MIGRATABLE_KINDS table, late arrival and the CLI round trip.
# C6: table-driven case over every MIGRATABLE_KINDS entry
case_begin "all-migratable-kinds" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"

REG_JS="$_BASIC_SCRIPT_CHECKOUT_ROOT/hooks/lib/plans-artifact-registry.js"
# The kind list comes from the registry's MIGRATABLE_KINDS, not from this file.
# SAMPLES only supplies one concrete control-file name per kind (a regex kind
# has no canonical instance); the driver fails any MIGRATABLE_KINDS entry that
# no sample instantiates, so a newly added kind cannot pass untested.
cat > "$T/samples.txt" <<'SAMPLES'
security-code-exit6-accepted.txt review-plan-security-exit6-accepted.txt review-tests-exit6-accepted.txt
outline-risk-signal.txt detail-risk-signal.txt codex-context.md plan.jsonl changed-files.txt
complexity-signals.txt detail-signals.txt write-tests-signals.txt write-code-signals.txt
finalize-state-1.json finalize-binding-1.json issue-close-outcome.json session-close-gate.json
final-report-env.json supervisor-state.json wi-checkpoint.json handoff.md wt-cleanup-active
handoff-risk.json handoff-pressure.json handoff-flush-mark.json
workflow-init-aborted-pathA-multiN-label-failure.md companion-precheck.json intent-scan-block.txt
worker-main.json worker-main-1.json worker-main-1.dispatched
SAMPLES
for fmt in outline-plan detail-plan test-review security-code security-plan review-security-shared; do
  for sfx in round-number.txt last-round.txt terminal.txt unresolved-concerns.json concern-ledger.txt \
             concern-ledger-cycle1.txt concern-ledger-cap-snapshot.txt concern-carrier.md round-1-delta-codex.txt; do
    printf '%s\n' "${fmt}-${sfx}" >> "$T/samples.txt"
  done
  printf '%s\n' "codex-context.${fmt}.built" >> "$T/samples.txt"
done
cat > "$T/kinds-driver.js" <<'JS'
// kinds-driver.js <seed|verify> <regJs> <sid> <plansDir> <ctlDir> <samplesFile>
// seed: every MIGRATABLE_KINDS entry gets >=1 sample, each sample is seeded
// at legacyBasename(sid, name) with noncanonical bytes, and a copy is kept in
// <expDir>. verify: every seeded file reached the control dir byte-identical
// (no bodies embed a path, so none is a rewrite target) and left PLANS_DIR.
const fs = require("fs"), path = require("path");
const [op, regJs, sid, plansDir, ctlDir, samplesFile, expDir] = process.argv.slice(2);
let reg;
try { reg = require(regJs); } catch (e) { console.log("FAIL implementation missing: " + regJs); process.exit(0); }
const kinds = Array.isArray(reg.MIGRATABLE_KINDS) ? reg.MIGRATABLE_KINDS : [];
if (kinds.length === 0) { console.log("FAIL MIGRATABLE_KINDS is missing or empty"); process.exit(0); }
const reOf = (k) => { const r = k instanceof RegExp ? k : k && (k.re || k.regex || k.pattern);
  return r instanceof RegExp ? r : typeof r === "string" ? new RegExp(r) : null; };
const idOf = (k) => (k && (k.kind || k.name || k.id)) || String(reOf(k) || k);
const full = (k, s) => { if (typeof k === "string") return k === s; const r = reOf(k); const m = r && s.match(r); return !!m && m[0] === s; };
const samples = fs.readFileSync(samplesFile, "utf8").split(/\s+/).filter(Boolean);
const legacy = (n) => (typeof reg.legacyBasename === "function" ? reg.legacyBasename(sid, n) : `${sid}-${n}`);
// Noncanonical shapes: odd whitespace, unsorted keys, CRLF, tabs, non-ASCII,
// and every trailing-newline variant (none, LF, CRLF, doubled). A migration
// that re-serializes JSON or normalizes line endings changes these bytes.
const JSON_SHAPES = [
  (n) => `{"sample" :"${n}",   "z":1,"a" : [ 1,2 ,3 ]}`,
  (n) => `{\r\n\t"z": {"y":1, "x":0},\r\n\t"sample": "${n}"\r\n}\r\n`,
  (n) => `  {  "b":true , "sample":"${n}" ,"a":null }  \n\n`,
  (n) => `{"sample":"${n}","note":"café \\u00e9 \\/"}\n`,
];
const TEXT_SHAPES = [
  (n) => `body-${n}`,
  (n) => `body-${n}  \r\nline2\t\r\n`,
  (n) => `\n\tbody-${n}\n\n`,
  (n) => `café-${n} trailing \n`,
];
const body = (n, i) => Buffer.from((n.endsWith(".json") ? JSON_SHAPES : TEXT_SHAPES)[i % 4](n), "utf8");
let bad = 0;
if (op === "seed") {
  for (const k of kinds) if (!samples.some((s) => full(k, s))) { bad++; console.log(`FAIL untested MIGRATABLE_KINDS entry: ${idOf(k)} (add a sample name)`); }
  fs.mkdirSync(expDir, { recursive: true });
  samples.forEach((s, i) => {
    if (!kinds.some((k) => full(k, s))) { bad++; console.log(`FAIL sample is not a MIGRATABLE kind: ${s}`); return; }
    fs.writeFileSync(path.join(plansDir, legacy(s)), body(s, i));
    fs.writeFileSync(path.join(expDir, s), body(s, i));
  });
  console.log(bad ? "SEED-BAD" : `SEEDED ${samples.length} for ${kinds.length} kinds`);
} else {
  for (const s of samples) {
    const dst = path.join(ctlDir, s), src = path.join(plansDir, legacy(s));
    let got = null; try { got = fs.readFileSync(dst); } catch (e) {}
    const want = fs.readFileSync(path.join(expDir, s));
    if (got === null) { bad++; console.log(`FAIL dst-missing: ${s}`); }
    else if (!got.equals(want)) { bad++; console.log(`FAIL bytes differ: ${s}`); }
    if (fs.existsSync(src)) { bad++; console.log(`FAIL src-not-removed: ${s}`); }
  }
  console.log(bad ? "VERIFY-BAD" : "VERIFIED");
}
JS
kinds_driver() { node "$T/kinds-driver.js" "$1" "$(np "$REG_JS")" "$SID" "$(np "$T/plans")" "$(np "$T/workflow-state/${SID}.control")" "$(np "$T/samples.txt")" "$(np "$T/expected")" 2>&1 | tr -d '\r'; }

# Short-lived markers are control kinds but not MIGRATABLE_KINDS: they must
# never land in the control dir (the plan retires them in place).
EPHEMERAL="guard-attempt.tmp"
for e in $EPHEMERAL; do printf 'eph' > "$T/plans/${SID}-${e}"; done
# #2544: an outcome or ingested marker never belongs in PLANS_DIR, so a planted one must
# not be carried into the control dir where the hook would trust it.
NEVER_MIGRATED="worker-test-runner-1.outcome.json worker-test-runner-1.ingested"
for e in $NEVER_MIGRATED; do printf '{"planted":true}' > "$T/plans/${SID}-${e}"; done
NM_KINDS="$(node -e '
const r = require(process.argv[1]);
const names = ["worker-test-runner-1.outcome.json", "worker-test-runner-1.ingested"];
const hit = (list, n) => list.filter((c) => { const m = n.match(c.re || c.regex || c.pattern); return m && m[0] === n; }).map((c) => c.kind);
process.stdout.write(names.map((n) => n + ":control=" + hit(r.CONTROL_KINDS || [], n).join("+") + ":migratable=" + hit(r.MIGRATABLE_KINDS || [], n).join("+")).join(" "));
' "$(np "$REG_JS")" 2>&1 | tr -d '\r')"
if [ "$NM_KINDS" = "worker-test-runner-1.outcome.json:control=worker-outcome:migratable= worker-test-runner-1.ingested:control=worker-ingested:migratable=" ]; then
  pass "all-migratable-kinds:outcome-kinds-registered-but-not-migratable"
else
  fail "all-migratable-kinds:outcome-kinds-registered-but-not-migratable" "got $NM_KINDS"
fi

# Artifact files that must NOT move out of PLANS_DIR
printf '# detail\n' > "$T/plans/${SID}-detail.md"
printf '# intent\n' > "$T/plans/${SID}-intent.md"
printf '# context\n' > "$T/plans/${SID}-context.md"
printf '# worker draft\n' > "$T/plans/${SID}-worker-main-1.draft.json"

SEED_OUT="$(kinds_driver seed)"
if ! printf '%s\n' "$SEED_OUT" | grep -q '^SEEDED '; then
  printf '%s\n' "$SEED_OUT" | grep '^FAIL' | while IFS= read -r l; do echo "  $l"; done
  fail "all-migratable-kinds:seed" "$(printf '%s\n' "$SEED_OUT" | grep '^FAIL' | head -1)"
else
  RES=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
  if ! printf '%s' "$RES" | grep -q '^OK:'; then
    fail "all-migratable-kinds" "migrateSession failed: $RES (implementation missing)"
  else
    ALL_OK=1
    VER_OUT="$(kinds_driver verify)"
    if ! printf '%s\n' "$VER_OUT" | grep -q '^VERIFIED$'; then
      printf '%s\n' "$VER_OUT" | grep '^FAIL' | while IFS= read -r l; do echo "  $l"; done
      fail "all-migratable-kinds:verify" "$(printf '%s\n' "$VER_OUT" | grep -c '^FAIL') kind sample(s) not migrated intact"
      ALL_OK=0
    fi
    CMP_BAD=0
    for exp in "$T/expected"/*; do
      [ -f "$exp" ] || continue
      bn="$(basename "$exp")"
      if ! cmp -s "$exp" "$T/workflow-state/${SID}.control/$bn"; then
        echo "  cmp differs or missing: $bn"; CMP_BAD=$((CMP_BAD + 1))
      fi
    done
    if [ "$CMP_BAD" -gt 0 ]; then
      fail "all-migratable-kinds:cmp" "$CMP_BAD migrated file(s) not byte-identical (cmp)"
      ALL_OK=0
    fi
    for art in "${SID}-detail.md" "${SID}-intent.md" "${SID}-context.md" "${SID}-worker-main-1.draft.json"; do
      if [ ! -f "$T/plans/$art" ]; then
        fail "all-migratable-kinds:artifact-moved:${art}" "artifact incorrectly removed from PLANS_DIR"
        ALL_OK=0
      fi
    done
    for e in $EPHEMERAL; do
      if [ -e "$T/workflow-state/${SID}.control/${e}" ]; then
        fail "all-migratable-kinds:ephemeral-moved:${e}" "short-lived marker was migrated"
        ALL_OK=0
      fi
    done
    for e in $NEVER_MIGRATED; do
      if [ -e "$T/workflow-state/${SID}.control/${e}" ]; then
        fail "all-migratable-kinds:outcome-kind-moved:${e}" "a PLANS_DIR outcome-kind file reached the control dir"
        ALL_OK=0
      fi
    done
    [ "$ALL_OK" -eq 1 ] && pass "all-migratable-kinds"
  fi
fi
rm -rf "$T"
case_end

# C6: late-arrival — after initial migration a legacy control file appears; re-enter migrates it
case_begin "late-arrival-legacy" "hooks/lib/temporary-migrations/control-dir-split/index.js"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"

# First migration: one legacy control file
printf 'terminal-v1\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
RES1=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
if ! printf '%s' "$RES1" | grep -q '^OK:'; then
  fail "late-arrival-legacy" "first migration failed: $RES1 (implementation missing)"
else
  DST1="$T/workflow-state/${SID}.control/detail-plan-terminal.txt"
  if [ ! -f "$DST1" ]; then
    fail "late-arrival-legacy:first-dst-missing" "first migration produced no destination"
  else
    # Late arrival: a new legacy control file appears (simulating months-late pull)
    printf 'late-round-2\n' > "$T/plans/${SID}-detail-plan-round-number.txt"
    # Re-enter migration
    RES2=$(run_migrate_session "$SID" "$(np "$T/workflow-state")" "$(np "$T/plans")")
    if ! printf '%s' "$RES2" | grep -q '^OK:'; then
      fail "late-arrival-legacy:re-migrate" "re-migration failed: $RES2"
    else
      DST2="$T/workflow-state/${SID}.control/detail-plan-round-number.txt"
      SRC2="$T/plans/${SID}-detail-plan-round-number.txt"
      if [ ! -f "$DST2" ]; then
        fail "late-arrival-legacy:late-dst-missing" "late-arrival file not migrated to control dir"
      elif [ -f "$SRC2" ]; then
        fail "late-arrival-legacy:late-src-not-removed" "late-arrival legacy source not removed"
      else
        GOT=$(cat "$DST2" 2>/dev/null || echo MISSING)
        if [ "$GOT" = "late-round-2" ]; then
          pass "late-arrival-legacy"
        else
          fail "late-arrival-legacy:content" "want late-round-2 got $GOT"
        fi
      fi
    fi
  fi
fi
rm -rf "$T"
case_end

# Codex round 4 C6: the manual CLI end to end — migrate, remove sources, keep exact
# bytes, re-run as a no-op, then a conflict that is reported and never overwrites.
# Conflict is not "failed" (plan Step 3: failed -> exit 1), so its exit is 0 or 1;
# the contract under test is the stderr report, the log line and dst-wins.
case_begin "cli-round-trip-and-conflict" "bin/migrate-control-dir"
T=$(make_tmp)
harness_isolate "$T"
SID="$UUID"
CTL="$T/workflow-state/${SID}.control"
mkdir -p "$T/expected"
printf 'exit=6\r\nfp=abc\r\n' > "$T/expected/detail-plan-terminal.txt"
printf '2' > "$T/expected/detail-plan-round-number.txt"
cp "$T/expected/detail-plan-terminal.txt" "$T/plans/${SID}-detail-plan-terminal.txt"
cp "$T/expected/detail-plan-round-number.txt" "$T/plans/${SID}-detail-plan-round-number.txt"
printf '# detail\n' > "$T/plans/${SID}-detail.md"
if [ ! -f "$MIGRATE_CLI" ]; then
  fail "cli-round-trip-and-conflict" "bin/migrate-control-dir not found (implementation absent)"
else
  rc=0
  node "$MIGRATE_CLI" --session "$SID" >"$T/out1.txt" 2>"$T/err1.txt" || rc=$?
  if [ "$rc" = "0" ]; then pass "cli-round-trip: first run exits 0"
  else fail "cli-round-trip: first run exits 0" "got $rc: $(cat "$T/err1.txt")"; fi
  for bn in detail-plan-terminal.txt detail-plan-round-number.txt; do
    if cmp -s "$T/expected/$bn" "$CTL/$bn"; then
      pass "cli-round-trip: $bn migrated byte-for-byte"
    else
      fail "cli-round-trip: $bn migrated byte-for-byte" "destination missing or bytes differ"
    fi
    if [ -e "$T/plans/${SID}-$bn" ]; then
      fail "cli-round-trip: legacy $bn removed" "source still in PLANS_DIR"
    else
      pass "cli-round-trip: legacy $bn removed"
    fi
  done
  if [ -f "$T/plans/${SID}-detail.md" ] && [ ! -e "$CTL/detail.md" ]; then
    pass "cli-round-trip: the artifact stays in PLANS_DIR"
  else
    fail "cli-round-trip: the artifact stays in PLANS_DIR" "detail.md moved or lost"
  fi
  rc=0
  node "$MIGRATE_CLI" --session "$SID" >/dev/null 2>"$T/err2.txt" || rc=$?
  if [ "$rc" = "0" ]; then pass "cli-round-trip: re-run is an idempotent no-op (exit 0)"
  else fail "cli-round-trip: re-run is an idempotent no-op (exit 0)" "got $rc: $(cat "$T/err2.txt")"; fi
  if cmp -s "$T/expected/detail-plan-terminal.txt" "$CTL/detail-plan-terminal.txt"; then
    pass "cli-round-trip: re-run leaves the destination bytes alone"
  else
    fail "cli-round-trip: re-run leaves the destination bytes alone" "destination changed on re-run"
  fi
  # Conflict: a stale legacy terminal with different bytes reappears.
  printf 'exit=2\nfp=stale\n' > "$T/plans/${SID}-detail-plan-terminal.txt"
  cp "$T/plans/${SID}-detail-plan-terminal.txt" "$T/stale-src.txt"
  rc=0
  node "$MIGRATE_CLI" --session "$SID" >"$T/out3.txt" 2>"$T/err3.txt" || rc=$?
  case "$rc" in
    0|1) pass "cli-conflict: exit $rc is within the CLI contract" ;;
    *) fail "cli-conflict: exit is 0 or 1" "got $rc: $(cat "$T/err3.txt")" ;;
  esac
  if cmp -s "$T/expected/detail-plan-terminal.txt" "$CTL/detail-plan-terminal.txt"; then
    pass "cli-conflict: the destination wins (not overwritten)"
  else
    fail "cli-conflict: the destination wins (not overwritten)" "destination was replaced by the stale source"
  fi
  if cmp -s "$T/stale-src.txt" "$T/plans/${SID}-detail-plan-terminal.txt"; then
    pass "cli-conflict: the conflicting source is kept byte-identical"
  else
    fail "cli-conflict: the conflicting source is kept byte-identical" "source removed or altered"
  fi
  if grep -qi 'conflict' "$T/err3.txt" "$T/out3.txt" 2>/dev/null && grep -qF 'detail-plan-terminal.txt' "$T/err3.txt" "$T/out3.txt" 2>/dev/null; then
    pass "cli-conflict: the CLI reports the conflict and names the file"
  else
    fail "cli-conflict: the CLI reports the conflict and names the file" "stdout/stderr: $(cat "$T/out3.txt" "$T/err3.txt" 2>/dev/null)"
  fi
  if grep -F "$SID" "$T/workflow-state/control-migration.log" 2>/dev/null | grep -qF 'detail-plan-terminal.txt'; then
    pass "cli-conflict: control-migration.log records the conflict"
  else
    fail "cli-conflict: control-migration.log records the conflict" "no log line for $SID detail-plan-terminal.txt"
  fi
fi
rm -rf "$T"
case_end
