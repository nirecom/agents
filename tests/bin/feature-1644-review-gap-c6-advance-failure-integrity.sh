#!/usr/bin/env bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/advance.js, bin/workflow/record-skip-judgment, bin/workflow/set-workflow-type, bin/workflow/record-complexity-and-skip, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, failure-injection, transaction-integrity, fail-closed, scope:issue-specific, pwsh-not-required

# #1644 review gap C6 (HIGH) — the forward operation under an INJECTED record
# failure: all four advance-class CLIs must return no next action AND leave no
# half-applied state. Two structural, platform-independent injections (chmod is a
# no-op on Git-Bash), each proven to fail by a control call (C6-0):
#   I1  WORKFLOW_STATE_DIR is a REGULAR FILE (or a deep path under it) -> ENOTDIR.
#   I2  the session's state file is unparseable JSON -> CorruptStateFileError.

# TL3 gap: a read-only filesystem or POSIX permission denial, a torn write, and a
# live session swallowing the nonzero exit (WORKFLOW_USER_VERIFIED preflight).

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SCRIPT_CHECKOUT_ROOT_N="$(nrm "$SCRIPT_CHECKOUT_ROOT")"
NS="$SCRIPT_CHECKOUT_ROOT_N/bin/workflow/next-step"
RSJ="$SCRIPT_CHECKOUT_ROOT_N/bin/workflow/record-skip-judgment"
SWT="$SCRIPT_CHECKOUT_ROOT_N/bin/workflow/set-workflow-type"
RCAS="$SCRIPT_CHECKOUT_ROOT/bin/workflow/record-complexity-and-skip"
WFSTATE_MODULE="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state"; export WFSTATE_MODULE
PROBE="$SCRIPT_CHECKOUT_ROOT_N/tests/bin/feature-1644-advance-transaction/state-probe.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Pinned as a PAIR (#1799) so supervisor-emit never appends to the real ~/.workflow-plans.
export WORKFLOW_STATE_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_MAIN_ROOT="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- expected [$2] in: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 -- did NOT expect [$2] in: $3"; else pass "$1"; fi
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
make_state() {
  local sid="$1" complete="$2" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[1644]}" > "$WORKFLOW_DIR/${sid}.json"
}
at_outline() { make_state "$1" "workflow_init clarify_intent research"; }

OUT=""; ERR=""; RC=0
run_cli() {
  local errf="$TMPDIR_BASE/cli.err"
  RC=0
  OUT="$(run_with_timeout "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
action_lines()   { printf '%s\n' "$OUT" | grep -c '^ACTION=' || true; }
advanced_lines() { printf '%s\n' "$OUT" | grep -c '^ADVANCED=' || true; }
# Byte-exact file snapshot: "unchanged" means unchanged, not "same projection".
file_snapshot() { printf '%s:' "$(wc -c < "$1" 2>/dev/null || echo missing)"; cat "$1" 2>/dev/null || true; }
dir_listing()   { ls -1 "$WORKFLOW_DIR" 2>/dev/null | sort | tr '\n' ' '; }

# --- I1 fixture: a regular file where a directory is expected (ENOTDIR everywhere).
BLOCK="$TMPDIR_BASE/blockfile"; printf 'not-a-directory\n' > "$BLOCK"
BLOCK_N="$(nrm "$BLOCK")"
DEEP_N="$BLOCK_N/a/b/c"
BLOCK_BEFORE="$(file_snapshot "$BLOCK")"

echo "=== C6-0: both injections are proven to actually fail ==="
# Control: the SAME call with no injection must succeed. Without this, every
# assertion below could be passing for an unrelated reason.
at_outline c60ctl
run_cli node "$NS" --session c60ctl --advance --step outline --status skipped \
  --skip-reason "the approach is already fixed by the issue body"
check "C6-0a: control (no injection) exits 0" 0 "$RC"

at_outline c60i1
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" node "$NS" --session c60i1 --advance \
  --step outline --status skipped --skip-reason "the approach is already fixed by the issue body"
check "C6-0b: injection I1 (regular file as workflow dir) does fail" 2 "$RC"
check_contains "C6-0b: the diagnostic names a write failure" "failed to write state" "$ERR"

printf '{ this is not json' > "$WORKFLOW_DIR/c60i2.json"
run_cli node "$NS" --session c60i2 --advance --step outline --status skipped \
  --skip-reason "the approach is already fixed by the issue body"
check "C6-0c: injection I2 (corrupt state JSON) does fail" 2 "$RC"
check_contains "C6-0c: the diagnostic names the invalid JSON" "not valid JSON" "$ERR"

echo ""
echo "=== C6-1: I1 — no ACTION, no ADVANCED, no half-applied state (all 4 CLIs) ==="
# next-step. --next is passed everywhere: the whole point is that a failed record
# withholds the ACTION block the caller asked for.
DIR_BEFORE="$(dir_listing)"
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" node "$NS" --session c61ns --advance \
  --step research --status complete --next
check "C6-1a: next-step exits 2" 2 "$RC"
check "C6-1a: zero ACTION lines" 0 "$(action_lines)"
check "C6-1a: zero ADVANCED lines" 0 "$(advanced_lines)"
check_not_contains "C6-1a: no NEXT_SKILL line" "NEXT_SKILL=" "$OUT"

# record-skip-judgment normalizes its write-verification failure to 2 on the
# --advance path (it is 1 without --advance — asserted below as the control).
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" node "$RSJ" --session c61rsj \
  --target outline --c1 true --c2 true --advance --next
check "C6-1b: record-skip-judgment exits 2" 2 "$RC"
check "C6-1b: zero ACTION lines" 0 "$(action_lines)"
check "C6-1b: zero ADVANCED lines" 0 "$(advanced_lines)"
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" node "$RSJ" --session c61rsj \
  --target outline --c1 true --c2 true
check "C6-1b: WITHOUT --advance the same failure keeps the frozen exit 1" 1 "$RC"

# set-workflow-type fails in its own workflow_type transaction, BEFORE runAdvance.
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" node "$SWT" --session c61swt \
  --type wf-meta --advance --step workflow_init --status complete --next
check "C6-1c: set-workflow-type exits 2" 2 "$RC"
check "C6-1c: zero ACTION lines" 0 "$(action_lines)"
check "C6-1c: zero ADVANCED lines" 0 "$(advanced_lines)"
check_not_contains "C6-1c: not even the WORKFLOW_TYPE prefix line is emitted" "WORKFLOW_TYPE=" "$OUT"
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" node "$SWT" --session c61swt --type wf-meta
check "C6-1c: WITHOUT --advance the same failure keeps the frozen exit 1" 1 "$RC"

# record-complexity-and-skip normalizes EVERY advance-path child failure to 3.
run_cli env WORKFLOW_STATE_DIR="$BLOCK_N" \
  bash "$RCAS" --session c61rcas --signals "" --target outline --advance
check "C6-1d: record-complexity-and-skip exits 3" 3 "$RC"
check "C6-1d: zero ACTION lines" 0 "$(action_lines)"
check "C6-1d: zero ADVANCED lines" 0 "$(advanced_lines)"

# Nothing created: not in the workflow dir, not by clobbering the blocking file.
check "C6-1e: the workflow dir listing is unchanged" "$DIR_BEFORE" "$(dir_listing)"
check "C6-1e: the blocking regular file is byte-for-byte unchanged" \
  "$BLOCK_BEFORE" "$(file_snapshot "$BLOCK")"

echo ""
echo "=== C6-2: I1 with a nonexistent DEEP path under the regular file ==="
# One level further out: the lock directory itself cannot be created — a
# different call site (mkdir, not open) from C6-1.
run_cli env WORKFLOW_STATE_DIR="$DEEP_N" node "$NS" --session c62ns --advance \
  --step research --status complete --next
check "C6-2a: next-step exits 2" 2 "$RC"
check "C6-2a: zero ACTION lines" 0 "$(action_lines)"
check "C6-2a: zero ADVANCED lines" 0 "$(advanced_lines)"
check_contains "C6-2a: the diagnostic names the directory error" "ENOTDIR" "$ERR"
run_cli env WORKFLOW_STATE_DIR="$DEEP_N" node "$SWT" --session c62swt \
  --type wf-meta --advance --step workflow_init --status complete --next
check "C6-2b: set-workflow-type exits 2" 2 "$RC"
check "C6-2b: zero ADVANCED lines" 0 "$(advanced_lines)"
run_cli env WORKFLOW_STATE_DIR="$DEEP_N" \
  bash "$RCAS" --session c62rcas --signals "" --target outline --advance
check "C6-2c: record-complexity-and-skip exits 3" 3 "$RC"
check "C6-2c: zero ADVANCED lines" 0 "$(advanced_lines)"
check "C6-2d: the blocking regular file is still byte-for-byte unchanged" \
  "$BLOCK_BEFORE" "$(file_snapshot "$BLOCK")"

echo ""
echo "=== C6-3: I2 — a corrupt state file is never partially rewritten ==="
CORRUPT_BYTES='{ "steps": { "outline": broken'
for sid in c63ns c63rsj c63swt c63rcas; do
  printf '%s' "$CORRUPT_BYTES" > "$WORKFLOW_DIR/${sid}.json"
done
C63_BEFORE="$(file_snapshot "$WORKFLOW_DIR/c63ns.json")"

run_cli node "$NS" --session c63ns --advance --step research --status complete --next
check "C6-3a: next-step exits 2" 2 "$RC"
check "C6-3a: zero ACTION lines" 0 "$(action_lines)"
check "C6-3a: zero ADVANCED lines" 0 "$(advanced_lines)"
check "C6-3a: the corrupt file is byte-for-byte unchanged" \
  "$C63_BEFORE" "$(file_snapshot "$WORKFLOW_DIR/c63ns.json")"

run_cli node "$RSJ" --session c63rsj --target outline --c1 true --c2 true --advance --next
check "C6-3b: record-skip-judgment exits 2" 2 "$RC"
check "C6-3b: zero ADVANCED lines" 0 "$(advanced_lines)"
check "C6-3b: the corrupt file is byte-for-byte unchanged" \
  "$C63_BEFORE" "$(file_snapshot "$WORKFLOW_DIR/c63rsj.json")"

run_cli node "$SWT" --session c63swt --type wf-meta --advance --step workflow_init --status complete --next
check "C6-3c: set-workflow-type exits 2" 2 "$RC"
check "C6-3c: zero ADVANCED lines" 0 "$(advanced_lines)"
check "C6-3c: the corrupt file is byte-for-byte unchanged" \
  "$C63_BEFORE" "$(file_snapshot "$WORKFLOW_DIR/c63swt.json")"

run_cli env bash "$RCAS" \
  --session c63rcas --signals "" --target outline --advance
check "C6-3d: record-complexity-and-skip exits 3" 3 "$RC"
check "C6-3d: zero ADVANCED lines" 0 "$(advanced_lines)"
check "C6-3d: the corrupt file is byte-for-byte unchanged" \
  "$C63_BEFORE" "$(file_snapshot "$WORKFLOW_DIR/c63rcas.json")"

echo ""
echo "=== C6-4: record-complexity-and-skip normalizes a failure in EACH delegated step ==="
# Three delegated steps, three injection points: without per-step coverage the
# exit-3 normalization could be implemented on one branch only. The script finds
# its delegates from its own location, so each stub tree runs its own copy of it.
NOOP='#!/usr/bin/env node
process.exit(0);
'
fake_rcas() {  # <fake-tree> — copies the script under test beside the tree's stubs
  cp "$RCAS" "$1/bin/workflow/record-complexity-and-skip"
  printf '%s' "$1/bin/workflow/record-complexity-and-skip"
}
# Step 1 fails: the complexity evaluation itself refuses.
mkdir -p "$TMPDIR_BASE/fake1/bin/workflow" "$TMPDIR_BASE/fake1/hooks/workflow-state"
printf '#!/usr/bin/env node\nprocess.stderr.write("stub: step1 refused\\n");\nprocess.exit(7);\n' \
  > "$TMPDIR_BASE/fake1/bin/workflow/record-complexity-evaluation"
printf 'module.exports={resolveSkipConditionsFromComplexity:()=>true};\n' \
  > "$TMPDIR_BASE/fake1/hooks/workflow-state/skip-signal-resolver.js"
printf '%s' "$NOOP" > "$TMPDIR_BASE/fake1/bin/workflow/record-skip-judgment"
at_outline c64a
run_cli env bash "$(fake_rcas "$TMPDIR_BASE/fake1")" \
  --session c64a --signals "" --target outline --advance
check "C6-4a: a step-1 failure is normalized to 3 (not the child's 7)" 3 "$RC"
check "C6-4a: zero ADVANCED lines" 0 "$(advanced_lines)"
check_not_contains "C6-4a: no SKIP_MODE line — step 1 failed before it" "SKIP_MODE=" "$OUT"
check "C6-4a: outline is untouched" '"pending"' \
  "$(PROBE_SID=c64a PROBE_STEP=outline PROBE_FIELD=status run_with_timeout node "$PROBE" field 2>/dev/null)"

# Step 2 fails: the skip-signal resolver throws.
mkdir -p "$TMPDIR_BASE/fake2/bin/workflow" "$TMPDIR_BASE/fake2/hooks/workflow-state"
printf '%s' "$NOOP" > "$TMPDIR_BASE/fake2/bin/workflow/record-complexity-evaluation"
printf 'throw new Error("stub: resolver unavailable");\n' \
  > "$TMPDIR_BASE/fake2/hooks/workflow-state/skip-signal-resolver.js"
printf '%s' "$NOOP" > "$TMPDIR_BASE/fake2/bin/workflow/record-skip-judgment"
at_outline c64b
run_cli env bash "$(fake_rcas "$TMPDIR_BASE/fake2")" \
  --session c64b --signals "" --target outline --advance
check "C6-4b: a step-2 failure is normalized to 3" 3 "$RC"
check "C6-4b: zero ADVANCED lines" 0 "$(advanced_lines)"
check_not_contains "C6-4b: no SKIP_MODE line — the mode never resolved" "SKIP_MODE=" "$OUT"
check "C6-4b: outline is untouched" '"pending"' \
  "$(PROBE_SID=c64b PROBE_STEP=outline PROBE_FIELD=status run_with_timeout node "$PROBE" field 2>/dev/null)"

# Step 3 fails: the REAL record-skip-judgment, for a real reason (I2). A shim
# re-exports the production CLI, so the delegate under test is not a stub that
# merely returns a chosen exit code.
mkdir -p "$TMPDIR_BASE/fake3/bin/workflow" "$TMPDIR_BASE/fake3/hooks/workflow-state"
printf '%s' "$NOOP" > "$TMPDIR_BASE/fake3/bin/workflow/record-complexity-evaluation"
printf 'module.exports={resolveSkipConditionsFromComplexity:()=>true};\n' \
  > "$TMPDIR_BASE/fake3/hooks/workflow-state/skip-signal-resolver.js"
printf '#!/usr/bin/env node\nrequire(%s);\n' "\"$RSJ\"" \
  > "$TMPDIR_BASE/fake3/bin/workflow/record-skip-judgment"
printf '%s' "$CORRUPT_BYTES" > "$WORKFLOW_DIR/c64c.json"
C64C_BEFORE="$(file_snapshot "$WORKFLOW_DIR/c64c.json")"
run_cli env bash "$(fake_rcas "$TMPDIR_BASE/fake3")" \
  --session c64c --signals "" --target outline --advance
check "C6-4c: a step-3 failure is normalized to 3 (the delegate's own 2 is swallowed)" 3 "$RC"
check "C6-4c: zero ADVANCED lines" 0 "$(advanced_lines)"
check "C6-4c: zero ACTION lines" 0 "$(action_lines)"
# The resolved mode IS still reported: step 2 succeeded, so the caller learns it.
check_contains "C6-4c: the resolved SKIP_MODE is still reported" "SKIP_MODE=auto" "$OUT"
check_not_contains "C6-4c: no SKIP_DISPATCH line is minted after the failure" "SKIP_DISPATCH=" "$OUT"
check "C6-4c: the corrupt file is byte-for-byte unchanged" \
  "$C64C_BEFORE" "$(file_snapshot "$WORKFLOW_DIR/c64c.json")"

echo ""
echo "=== C6-5: no lock directory or lock file survives any failure path ==="
LOCKS="$(ls -d "$WORKFLOW_DIR"/*.lock 2>/dev/null | wc -l | tr -d ' ')"
check "C6-5: zero leftover lock entries in the workflow dir" 0 "$LOCKS"
BLOCK_LOCKS="$(ls -d "$BLOCK".lock 2>/dev/null | wc -l | tr -d ' ')"
check "C6-5: no lock entry was created next to the blocking file" 0 "$BLOCK_LOCKS"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
