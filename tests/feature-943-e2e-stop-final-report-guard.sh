#!/usr/bin/env bash
# tests/feature-943-e2e-stop-final-report-guard.sh
# Tests: hooks/stop-final-report-guard.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - The env file is seeded directly and the transcript is synthesized, so the
#   real worktree-end WE-9..WE-11 env-file write path and a live claude -p Stop
#   event are not exercised; heading-extraction edge cases from real assistant
#   turns only surface in a real session.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/stop-final-report-guard.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found: $HOOK" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On MSYS/Git-Bash, node resolves paths as native Windows; pass Windows-form
# paths to node-based hooks so env vars and file writes stay consistent.
# No-op on POSIX (cygpath absent).
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi

export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
export WORKFLOW_PLANS_DIR="$TMP/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

SID="feature943-frg-00000000-0000-0000-0000-000000000002"

# Transcript whose last assistant text lacks the Final Report heading.
TRANSCRIPT="$TMP/transcript.jsonl"
node -e '
  const fs = require("fs");
  const entry = { type: "assistant", message: { content: [{ type: "text", text: "Work is done." }] } };
  fs.writeFileSync(process.argv[1], JSON.stringify(entry) + "\n", "utf8");
' "$TRANSCRIPT"

run_hook() {
  printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | node "$HOOK"
}

# --- E1: no env file → pass (exit 0) ------------------------------------------
rm -f "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json" 2>/dev/null || true
set +e
OUT1="$(run_hook)"; EXIT1=$?
set -e
if [ "$EXIT1" -eq 0 ]; then
  pass "E1. no final-report env file → pass (exit 0)"
else
  fail "E1. no env file should pass but exit=$EXIT1 out=$OUT1"
fi

# --- E2: env file seeded, Final Report absent → block (exit 2) [ACTIVE] --------
printf '%s' '{"PR_NUMBER":"1"}' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT2="$(run_hook)"; EXIT2=$?
set -e
if [ "$EXIT2" -eq 2 ] && printf '%s' "$OUT2" | grep -q '"decision":"block"'; then
  pass "E2. env file present + Final Report missing → block (exit 2 + decision:block)"
else
  fail "E2. expected exit 2 + decision:block; got exit=$EXIT2 out=$OUT2"
fi

# --- E3: Final Report heading found but section headings missing → block -------
# Build a transcript with the ## Final Report heading but omit all sub-headings.
TRANSCRIPT_E3="$TMP/transcript-e3.jsonl"
node -e '
  const fs = require("fs");
  const sid = process.argv[1];
  const body = "## Final Report — " + sid + "\n\nSome content but no sub-headings.\n";
  const entry = { type: "assistant", message: { content: [{ type: "text", text: body }] } };
  fs.writeFileSync(process.argv[2], JSON.stringify(entry) + "\n", "utf8");
' "$SID" "$TRANSCRIPT_E3"
printf '%s' '{"PR_NUMBER":"1"}' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT3="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT_E3\"}" | node "$HOOK")"; EXIT3=$?
set -e
if [ "$EXIT3" -eq 2 ] && printf '%s' "$OUT3" | grep -q '"decision":"block"'; then
  pass "E3. Final Report heading present but section headings missing → block (exit 2 + decision:block)"
else
  fail "E3. expected exit 2 + decision:block for missing headings; got exit=$EXIT3 out=$OUT3"
fi

# --- E4: all headings present but <PLACEHOLDER> token → block ------------------
TRANSCRIPT_E4="$TMP/transcript-e4.jsonl"
node -e '
  const fs = require("fs");
  const schema = require(require("path").join(process.argv[3], "hooks", "lib", "final-report-schema.js"));
  const sid = process.argv[1];
  const headings = schema.getSectionHeadings(sid);
  const body = headings.join("\n\n") + "\n\n<PLACEHOLDER> needs substitution.\n";
  const entry = { type: "assistant", message: { content: [{ type: "text", text: body }] } };
  fs.writeFileSync(process.argv[2], JSON.stringify(entry) + "\n", "utf8");
' "$SID" "$TRANSCRIPT_E4" "$AGENTS_DIR"
printf '%s' '{"PR_NUMBER":"1"}' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT4="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT_E4\"}" | node "$HOOK")"; EXIT4=$?
set -e
if [ "$EXIT4" -eq 2 ] && printf '%s' "$OUT4" | grep -q '"decision":"block"'; then
  pass "E4. all headings present but <PLACEHOLDER> token → block (exit 2 + decision:block)"
else
  fail "E4. expected exit 2 + decision:block for placeholder token; got exit=$EXIT4 out=$OUT4"
fi

# --- E5: gate file gate_action:yield + Final Report absent → pass (yield) ------
# When session-close-gate.json has gate_action:yield, the hook exits 0 (fail-open).
printf '%s' '{"gate_action":"yield"}' > "$WORKFLOW_PLANS_DIR/$SID-session-close-gate.json"
printf '%s' '{"PR_NUMBER":"1"}' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT5="$(run_hook)"; EXIT5=$?
set -e
rm -f "$WORKFLOW_PLANS_DIR/$SID-session-close-gate.json"
if [ "$EXIT5" -eq 0 ]; then
  pass "E5. gate_action:yield + Final Report absent → yield (exit 0)"
else
  fail "E5. expected exit 0 (yield); got exit=$EXIT5 out=$OUT5"
fi

# --- E6: all headings present, no placeholder → pass (exit 0) [ACTIVE] --------
# Primary happy path: env file + Final Report heading + all 13 section headings
# + no <PLACEHOLDER> tokens → exit 0 (guards against accidental new block paths).
TRANSCRIPT_E6="$TMP/transcript-e6.jsonl"
node -e '
  const fs = require("fs");
  const schema = require(require("path").join(process.argv[3], "hooks", "lib", "final-report-schema.js"));
  const sid = process.argv[1];
  const headings = schema.getSectionHeadings(sid);
  // Join all headings with separator text and no <PLACEHOLDER> tokens.
  const body = headings.join("\n\nSection content here.\n\n") + "\n\nSection content here.\n";
  const entry = { type: "assistant", message: { content: [{ type: "text", text: body }] } };
  fs.writeFileSync(process.argv[2], JSON.stringify(entry) + "\n", "utf8");
' "$SID" "$TRANSCRIPT_E6" "$AGENTS_DIR"
printf '%s' '{"PR_NUMBER":"1"}' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT6="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT_E6\"}" | node "$HOOK")"; EXIT6=$?
set -e
if [ "$EXIT6" -eq 0 ]; then
  pass "E6. all headings present + no placeholder → pass (exit 0)"
else
  fail "E6. expected exit 0 for valid Final Report; got exit=$EXIT6 out=$OUT6"
fi

# --- E7: stop_hook_active=true fast-exit (guard against infinite re-blocking) --
printf '%s' '{"PR_NUMBER":"1"}' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT7="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":true}" | node "$HOOK")"; EXIT7=$?
set -e
if [ "$EXIT7" -eq 0 ]; then
  pass "E7. stop_hook_active=true → fast-exit (exit 0, no block)"
else
  fail "E7. stop_hook_active=true should short-circuit; got exit=$EXIT7 out=$OUT7"
fi

# --- E8: malformed env-file (JSON parse error) → fail-open (exit 0) -----------
printf '%s' 'NOT_VALID_JSON' > "$WORKFLOW_PLANS_DIR/$SID-final-report-env.json"
set +e
OUT8="$(run_hook)"; EXIT8=$?
set -e
if [ "$EXIT8" -eq 0 ]; then
  pass "E8. malformed env-file → fail-open (exit 0)"
else
  fail "E8. expected exit 0 (fail-open) for malformed env; got exit=$EXIT8 out=$OUT8"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
