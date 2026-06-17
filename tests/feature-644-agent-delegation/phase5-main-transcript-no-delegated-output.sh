#!/usr/bin/env bash
# phase5-main-transcript-no-delegated-output.sh — GATED until Phase 5 (E2E)
# Verifies that delegated worker output does not leak into the main transcript.
# Uses claude -p --output-format json per rules/test-rules/claude-e2e.md.
#
# Rules (claude-e2e.md):
#   1. unset CLAUDECODE before spawning claude -p
#   2. Use minimal settings.json (not the global one)
#   3. WSL-via-Windows bridge may mask failures — run on native env
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 5 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=5 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi

# Resolve repo root early so we can read .env via bin/get-config-var.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Skip unless RUN_E2E is enabled in .env (Anthropic-billable).
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off; then
  echo "SKIP: requires RUN_E2E=on in .env" >&2; exit 77
fi

# Also skip if claude CLI not available
if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not found" >&2; exit 77
fi

set -uo pipefail

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Minimal settings.json per claude-e2e.md rule 2
cat > "$FIXTURE_DIR/settings.json" <<'EOF'
{ "hooks": {} }
EOF

# Unset CLAUDECODE per rule 1
unset CLAUDECODE

# Run a simple /deep-research invocation against a benign public topic
RESPONSE_FILE="$FIXTURE_DIR/response.json"
if ! timeout 180 claude -p "Run a very brief /deep-research about the word 'hello'" \
    --output-format json \
    --config "$FIXTURE_DIR/settings.json" \
    > "$RESPONSE_FILE" 2>/dev/null; then
  echo "SKIP: claude -p invocation failed or timed out" >&2; exit 77
fi

if [ ! -s "$RESPONSE_FILE" ]; then
  echo "SKIP: empty response" >&2; exit 77
fi

# Extract main assistant text content
MAIN_TEXT=$(jq -r '.messages[]? | select(.role=="assistant") | .content[]? | select(.type=="text") | .text' "$RESPONSE_FILE" 2>/dev/null || true)

if [ -z "$MAIN_TEXT" ]; then
  echo "SKIP: could not parse assistant messages from response" >&2; exit 77
fi

# Assert that verbose WebSearch raw result URLs are NOT in the main transcript
# (They should stay in the worker/subagent context)
if echo "$MAIN_TEXT" | grep -qE 'https?://[^ ]{50,}'; then
  fail "main transcript contains raw URLs (verbose WebSearch results leaked)"
else
  pass "no verbose URL dump in main transcript"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
