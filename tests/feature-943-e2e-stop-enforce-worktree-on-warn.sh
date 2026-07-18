#!/usr/bin/env bash
# tests/feature-943-e2e-stop-enforce-worktree-on-warn.sh
# Tests: hooks/stop-enforce-worktree-on-warn.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - The transcript is synthesized with the OFF sentinel embedded in a Bash
#   tool_use; a live claude -p session may format assistant tool_use entries
#   differently, so real-transcript parsing quirks only surface in a real run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/stop-enforce-worktree-on-warn.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found: $HOOK" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On MSYS/Git-Bash, node resolves paths as native Windows; pass Windows-form
# transcript paths so the hook reads them. No-op on POSIX (cygpath absent).
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi

SID="feature943-wow-00000000-0000-0000-0000-000000000007"

# Build a transcript whose assistant turns contain a Bash tool_use with $1 as command.
make_transcript() {
  local cmd="$1" out="$2"
  node -e '
    const fs = require("fs");
    const cmd = process.argv[1];
    const out = process.argv[2];
    const entry = { type: "assistant", message: { content: [
      { type: "tool_use", name: "Bash", input: { command: cmd } },
    ] } };
    fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
  ' "$cmd" "$out"
}

run_hook() {
  local transcript="$1"
  printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$transcript\"}" \
    | node "$HOOK"
}

# --- E1: no sentinel → pass (exit 0, no advisory) -----------------------------
T1="$TMP/t1.jsonl"
make_transcript 'echo hello world' "$T1"
set +e
OUT1="$(run_hook "$T1")"; EXIT1=$?
set -e
if [ "$EXIT1" -eq 0 ] && ! printf '%s' "$OUT1" | grep -q "ENFORCE_WORKTREE_OFF was proposed"; then
  pass "E1. no OFF sentinel → pass (exit 0, no advisory)"
else
  fail "E1. expected clean pass; got exit=$EXIT1 out=$OUT1"
fi

# --- E2: OFF sentinel without matching ON → advisory emitted [ACTIVE] ----------
T2="$TMP/t2.jsonl"
make_transcript 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>"' "$T2"
set +e
OUT2="$(run_hook "$T2")"; EXIT2=$?
set -e
if [ "$EXIT2" -eq 0 ] && printf '%s' "$OUT2" | grep -q "ENFORCE_WORKTREE_OFF was proposed"; then
  pass "E2. OFF sentinel unbalanced → advisory string emitted (exit 0)"
else
  fail "E2. expected advisory 'ENFORCE_WORKTREE_OFF was proposed'; got exit=$EXIT2 out=$OUT2"
fi

# --- E3: balanced OFF+ON sentinels → no advisory (exit 0, empty output) --------
# Build a transcript with two turns: first OFF, then ON.  The hook compares
# lastOffIdx vs lastOnIdx; ON > OFF → no advisory should be produced.
T3="$TMP/t3.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const off = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: temporarily off>>\"" } },
  ] } };
  const on  = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: restored>>\"" } },
  ] } };
  fs.writeFileSync(out, JSON.stringify(off) + "\n" + JSON.stringify(on) + "\n", "utf8");
' "$T3"
set +e
OUT3="$(run_hook "$T3")"; EXIT3=$?
set -e
if [ "$EXIT3" -eq 0 ] && ! printf '%s' "$OUT3" | grep -q "ENFORCE_WORKTREE_OFF was proposed"; then
  pass "E3. balanced OFF+ON sentinels → no advisory (exit 0)"
else
  fail "E3. expected no advisory for balanced sentinels; got exit=$EXIT3 out=$OUT3"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
