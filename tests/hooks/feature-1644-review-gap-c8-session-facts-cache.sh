#!/usr/bin/env bash
# tests/hooks/feature-1644-review-gap-c8-session-facts-cache.sh
# Tests: hooks/workflow-state/session-facts.js, hooks/lib/parse-closes-issues.js, hooks/workflow-state/state-io/core.js
# Tags: tl2, workflow, session-facts, closes-issues, security, path-traversal, idempotency, scope:issue-specific, pwsh-not-required
# #1644 C8 -- getClosesIssues() reads intent.md only; the state.closes_issues cache removed in
# #2654 must not return. C8-1 state value ignored, C8-3 edits followed + state bytes fixed,
# C8-4 no state file fabricated, C8-5 traversal ids rejected, C8-6 same-process re-read.
# TL3 gap: real call sites passing a session id (not a path); withStateLock races under a
# live Claude Code process. Mitigation: the guard is a pure-input classifier covered here.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SCRIPT_CHECKOUT_ROOT_N="$(nrm "$SCRIPT_CHECKOUT_ROOT")"
SF_MODULE_N="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state/session-facts.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"
  else fail "$1 -- expected [$2] in: $3"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# DUAL-PIN (#1799): a lone WORKFLOW_STATE_DIR would still let supervisor-emit
# append into the developer's real ~/.workflow-plans.
export WORKFLOW_STATE_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
PLANS_DIR_N="$(nrm "$PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_MAIN_ROOT="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
NEUTRAL_CWD="$TMPDIR_BASE/neutral"; mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

# --- fixture builders -------------------------------------------------------
STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# fixture_state <sid> <closes_issues-json-or-empty>
fixture_state() {
  local sid="$1" issues="${2:-}"
  local json='{"steps":{' first=1 s
  for s in $STEPS_ALL; do
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"pending\"}"
  done
  json="$json},\"cwd\":\"$FIXTURE_REPO\",\"git_branch\":\"feature/roundtrip-reduction\""
  if [ -n "$issues" ]; then json="$json,\"closes_issues\":$issues"; fi
  printf '%s' "$json}" > "$WORKFLOW_DIR/${sid}.json"
}

write_intent() {
  local sid="$1"; shift
  { echo "## Issues"; for tok in "$@"; do echo "- $tok"; done; } > "$PLANS_DIR/${sid}-intent.md"
}
rm_intent() { rm -f "$PLANS_DIR/${1}-intent.md"; }
raw_file_bytes() { cat "$WORKFLOW_DIR/${1}.json" 2>/dev/null || echo "<absent>"; }

# --- probes ------------------------------------------------------------------
GCI_PROBE="$TMPDIR_BASE/gci-probe.js"
cat > "$GCI_PROBE" <<'EOF'
const m = require(process.env.SF_MODULE);
try {
  const r = m.getClosesIssues(process.env.SF_SID, { plansDir: process.env.SF_PLANS_DIR });
  process.stdout.write(JSON.stringify(r));
} catch (e) {
  process.stdout.write("THREW: " + e.message);
  process.exit(3);
}
EOF

# gci <sid> -- returns the JSON result, or "THREW: <msg>" on a rejected id.
gci() {
  SF_MODULE="$SF_MODULE_N" SF_SID="$1" SF_PLANS_DIR="$PLANS_DIR_N" \
    run_with_timeout node "$GCI_PROBE" 2>/dev/null
}

# Snapshot every file under the temp base (relative paths, sorted) so a probe
# that escaped the pinned dirs is visible as a tree delta.
tree_snapshot() { (cd "$TMPDIR_BASE" && find . -type f | LC_ALL=C sort); }

echo "=== C8-1: a recorded closes_issues in state is ignored -- intent.md answers ==="
fixture_state c1 '[{"number":1644},{"number":1655}]'
write_intent c1 "#9999"
OUT="$(gci c1)"
check "C8-1a: intent.md wins over a contradicting recorded value in state" \
  '[{"number":9999}]' "$OUT"
rm_intent c1
check "C8-1b: with intent.md deleted the answer is [] (no fallback to state)" \
  '[]' "$(gci c1)"


echo ""
echo "=== C8-7: unreadable or empty intent.md with stale state -> [] (no fallback to state) ==="
fixture_state c7dir '[{"number":1644},{"number":1655}]'
rm_intent c7dir; mkdir -p "$PLANS_DIR/c7dir-intent.md"
check "C8-7a: intent.md path is a directory -> []" '[]' "$(gci c7dir)"
fixture_state c7zero '[{"number":1644},{"number":1655}]'
: > "$PLANS_DIR/c7zero-intent.md"
check "C8-7b: intent.md is 0 bytes -> []" '[]' "$(gci c7zero)"

echo ""
echo "=== C8-3: every call re-reads intent.md and the on-disk state bytes never move ==="
fixture_state c3
BYTES0="$(raw_file_bytes c3)"
write_intent c3 "#1644" "owner/repo#1655"
FIRST="$(gci c3)"
check "C8-3a: first call parses intent.md" \
  '[{"number":1644},{"number":1655,"repo":"owner/repo"}]' "$FIRST"
BYTES1="$(raw_file_bytes c3)"
write_intent c3 "#9999"   # rewrite the source of truth between calls
SECOND="$(gci c3)"
check "C8-3b: second call returns the rewritten intent.md set" '[{"number":9999}]' "$SECOND"
BYTES2="$(raw_file_bytes c3)"
THIRD="$(gci c3)"
check "C8-3c: third call is identical to the second" "$SECOND" "$THIRD"
BYTES3="$(raw_file_bytes c3)"
check "C8-3d: raw state bytes unchanged by call 1" "$BYTES0" "$BYTES1"
check "C8-3e: raw state bytes unchanged by call 2" "$BYTES1" "$BYTES2"
check "C8-3f: raw state bytes unchanged by call 3" "$BYTES2" "$BYTES3"

echo ""
echo "=== C8-6: one process, two calls -- an in-process 4 -> 2 narrowing is followed ==="
# Cross-process probes cannot see a module-level memo; this one shares a require() cache.
INPROC_PROBE="$TMPDIR_BASE/gci-inproc-probe.js"
cat > "$INPROC_PROBE" <<'EOF'
const fs = require("fs"), path = require("path");
const m = require(process.env.SF_MODULE);
const sid = process.env.SF_SID, dir = process.env.SF_PLANS_DIR;
const put = (toks) => fs.writeFileSync(path.join(dir, sid + "-intent.md"),
  "## Issues\n" + toks.map((t) => "- " + t + "\n").join(""));
put(["#1644", "#1655", "#1700", "#1701"]);
const a = m.getClosesIssues(sid, { plansDir: dir });
put(["#1644", "#1655"]);
const b = m.getClosesIssues(sid, { plansDir: dir });
process.stdout.write(JSON.stringify(a) + "\n" + JSON.stringify(b));
EOF
fixture_state c6
INPROC_OUT="$(SF_MODULE="$SF_MODULE_N" SF_SID=c6 SF_PLANS_DIR="$PLANS_DIR_N" \
  run_with_timeout node "$INPROC_PROBE" 2>&1)"
check "C8-6a: first in-process call sees all 4 issues" \
  '[{"number":1644},{"number":1655},{"number":1700},{"number":1701}]' "$(printf '%s\n' "$INPROC_OUT" | sed -n 1p)"
check "C8-6b: second in-process call sees the narrowed 2" \
  '[{"number":1644},{"number":1655}]' "$(printf '%s\n' "$INPROC_OUT" | sed -n 2p)"

echo ""
echo "=== C8-4: a MISSING state file is not auto-created ==="
rm -f "$WORKFLOW_DIR/c4.json"
write_intent c4 "#1644"
OUT="$(gci c4)"
check "C8-4a: the parsed value is returned even with no state file" '[{"number":1644}]' "$OUT"
if [ -e "$WORKFLOW_DIR/c4.json" ]; then
  fail "C8-4b: read-mostly call fabricated a state file -- $WORKFLOW_DIR/c4.json appeared"
else
  pass "C8-4b: no <sid>.json was fabricated in the workflow dir"
fi
# A second call must behave the same (still no state, still parses).
write_intent c4 "#4242"
check "C8-4c: with no state file, the next call still re-parses" '[{"number":4242}]' "$(gci c4)"
if [ -e "$WORKFLOW_DIR/c4.json" ]; then
  fail "C8-4d: state file appeared on the second stateless call"
else
  pass "C8-4d: still no state file after a second stateless call"
fi

echo ""
echo "=== C8-5: SECURITY -- assertValidSessionId rejects traversal-shaped ids ==="
# Table-driven over the whole shape family the guard must reject
# (SESSION_ID_VALID_RE = /^[A-Za-z0-9_-]+$/, applied BEFORE any path.join).
SNAP_BEFORE="$(tree_snapshot)"
BAD_IDS=(
  '../../etc/passwd'
  '..\\..\\x'
  'a/b'
  '/tmp/absolute-path'
  'C:/Windows/win.ini'
  '..'
  'a b'
  'a;rm -rf .'
  'sid$(echo hi)'
  'sid.json'
  ''
)
for bad in "${BAD_IDS[@]}"; do
  # Invoked inline (not through gci()) so the probe's exit code survives:
  # a rc set inside a command substitution is lost with the subshell.
  OUT="$(SF_MODULE="$SF_MODULE_N" SF_SID="$bad" SF_PLANS_DIR="$PLANS_DIR_N" \
    run_with_timeout node "$GCI_PROBE" 2>/dev/null)"
  RC=$?
  if [ "$RC" -eq 3 ]; then
    check_contains "C8-5: rejected [$bad] with an Invalid sessionId throw" "Invalid sessionId" "$OUT"
  else
    fail "C8-5: id [$bad] was NOT rejected -- rc=$RC out=[$OUT]"
  fi
done
SNAP_AFTER="$(tree_snapshot)"
check "C8-5z: no file was created or removed anywhere under the temp tree by the rejected ids" \
  "$SNAP_BEFORE" "$SNAP_AFTER"

# Symmetric positive case (CPR-ORTH): a well-formed id with the same character
# classes the guard allows must still be accepted -- otherwise C8-5 would pass
# on a guard that rejects everything.
fixture_state 'ok_Sid-123'
write_intent 'ok_Sid-123' "#1644"
check "C8-5y: a well-formed [A-Za-z0-9_-]+ id is accepted" '[{"number":1644}]' "$(gci 'ok_Sid-123')"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
