#!/usr/bin/env bash
# tests/feature-1644-review-gap-c8-session-facts-cache.sh
# Tests: hooks/workflow-state/session-facts.js, hooks/lib/parse-closes-issues.js, hooks/workflow-state/state-io/core.js
# Tags: tl2, workflow, session-facts, closes-issues, caching, security, path-traversal, idempotency, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C8 (HIGH) — getClosesIssues() cache semantics and its
# path-traversal guard. tests/feature-1644-session-facts.sh (G1-G8) covers the
# happy-path write-once contract; this file covers the four cases it does not:
#   1. an explicitly EMPTY cached closes_issues (the "resolved-vs-unresolved"
#      boundary of the `length > 0` condition),
#   2. idempotency proven on the raw on-disk bytes across repeated calls,
#   3. a MISSING state file must not be auto-created,
#   4. assertValidSessionId() rejecting traversal-shaped ids BEFORE any path
#      join, with no file touched outside the pinned workflow dir.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real hook/skill call sites pass the session id they think they
#   pass (a caller that hands getClosesIssues a *path* instead of a session id
#   would be rejected here, but only a real session proves the wiring).
# - Concurrent sessions racing on the same state file through the real
#   withStateLock file lock under a live Claude Code process.
# Closest-to-action mitigation: the traversal guard is a pure-input classifier;
# TL2 exercises the whole input domain that reaches it.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
SF_MODULE_N="$AGENTS_DIR_N/hooks/workflow-state/session-facts.js"

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
# DUAL-PIN (#1799): a lone CLAUDE_WORKFLOW_DIR would still let supervisor-emit
# append into the developer's real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
PLANS_DIR_N="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

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

RAWCLOSES_PROBE="$TMPDIR_BASE/rawcloses-probe.js"
cat > "$RAWCLOSES_PROBE" <<'EOF'
const wf = require(process.env.WFM);
const st = wf.readState(process.env.SF_SID);
const v = st && st.closes_issues !== undefined ? st.closes_issues : null;
process.stdout.write(JSON.stringify(v));
EOF
raw_closes() { WFM="$AGENTS_DIR_N/hooks/workflow-state" SF_SID="$1" run_with_timeout node "$RAWCLOSES_PROBE" 2>/dev/null || echo ""; }

# Snapshot every file under the temp base (relative paths, sorted) so a probe
# that escaped the pinned dirs is visible as a tree delta.
tree_snapshot() { (cd "$TMPDIR_BASE" && find . -type f | LC_ALL=C sort); }

echo "=== C8-1: cached NON-EMPTY closes_issues is returned without re-parsing ==="
fixture_state c1 '[{"number":1644},{"number":1655}]'
write_intent c1 "#9999"
OUT="$(gci c1)"
check "C8-1a: a non-empty cache wins over a contradicting intent.md" \
  '[{"number":1644},{"number":1655}]' "$OUT"
rm_intent c1
check "C8-1b: the cache still answers after intent.md is deleted" \
  '[{"number":1644},{"number":1655}]' "$(gci c1)"

echo ""
echo "=== C8-2: an EXPLICITLY EMPTY cached closes_issues is NOT a resolved answer ==="
# FINDING (pinned CURRENT behavior): session-facts.js treats only a NON-EMPTY
# array as "already resolved" (`Array.isArray(...) && length > 0`). An explicit
# `"closes_issues": []` in state is therefore indistinguishable from "never
# recorded" and triggers a re-parse of intent.md. Consequence: a session that
# legitimately closes ZERO issues never settles -- every call re-reads
# intent.md and re-writes state -- so a late edit to intent.md can still change
# the session's answer. Whether "[] means zero issues" should be honored as a
# resolved answer is a source-design question; this test pins what ships today.
fixture_state c2 '[]'
write_intent c2 "#1644"
OUT="$(gci c2)"
check "C8-2a: an empty cache does NOT suppress the parse -- intent.md wins" \
  '[{"number":1644}]' "$OUT"
check "C8-2b: the re-parsed value is written back over the empty cache" \
  '[{"number":1644}]' "$(raw_closes c2)"

# Second half of the finding: with intent.md ALSO yielding zero issues, the
# empty cache is rewritten as empty on every call and never becomes sticky.
fixture_state c2b '[]'
write_intent c2b   # "## Issues" heading with no entries -> parses to []
check "C8-2c: empty cache + empty intent.md returns []" '[]' "$(gci c2b)"
# Proof that the previous call did NOT serve a cached answer: change intent.md
# and the very next call reports the new issue set.
write_intent c2b "#7"
check "C8-2d: a later intent.md edit still changes the answer (re-parse, not cache)" \
  '[{"number":7}]' "$(gci c2b)"

echo ""
echo "=== C8-3: idempotency -- neither the answer nor the on-disk bytes move ==="
fixture_state c3
write_intent c3 "#1644" "owner/repo#1655"
FIRST="$(gci c3)"
check "C8-3a: first call parses intent.md" \
  '[{"number":1644},{"number":1655,"repo":"owner/repo"}]' "$FIRST"
BYTES1="$(raw_file_bytes c3)"
write_intent c3 "#9999"   # mutate the source of truth under the cache
SECOND="$(gci c3)"
check "C8-3b: second call returns the cached set, ignoring the mutation" "$FIRST" "$SECOND"
BYTES2="$(raw_file_bytes c3)"
THIRD="$(gci c3)"
check "C8-3c: third call is identical to the second" "$SECOND" "$THIRD"
BYTES3="$(raw_file_bytes c3)"
check "C8-3d: raw state bytes unchanged between call 1 and call 2" "$BYTES1" "$BYTES2"
check "C8-3e: raw state bytes unchanged between call 2 and call 3" "$BYTES2" "$BYTES3"

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
check "C8-4c: with no state to cache into, the next call re-parses" '[{"number":4242}]' "$(gci c4)"
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
