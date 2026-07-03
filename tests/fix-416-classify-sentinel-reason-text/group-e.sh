# shellcheck shell=bash
# Case group E: Edge inputs and dispatch guard.
# Sourced by fix-416-classify-sentinel-reason-text.sh; relies on helpers from common.sh.
# Tests execute inline on dot-source (no function wrapper).

echo ""
echo "--- Group E: Edge inputs and dispatch guard ---"

# T3.0a: classify(null) → "read" — null guard at top of classify()
assert_classify_raw \
  "T3.0a classify(null) → read (null guard)" \
  "null" \
  "read"

# T3.0b: classify("") → "read" — empty string is falsy, caught by !cmd guard
assert_classify_raw \
  "T3.0b classify('') → read (empty string guard)" \
  "''" \
  "read"

# T3.0c: classify(42) → "read" — non-string typeof guard
assert_classify_raw \
  "T3.0c classify(42) → read (non-string type guard)" \
  "42" \
  "read"

# T3.13i: empty reason in sentinel — [^>]+ requires ≥1 char; strict-sentinel
# regex fails → normal classify → no write pattern → read (accepted false-neg).
assert_classify \
  "T3.13i sentinel USER_VERIFIED with empty reason (isStrictSentinel false) → read" \
  'echo "<<WORKFLOW_USER_VERIFIED: >>"' \
  "read"

# T3.50: /tmp/ dispatch path — isKnownDispatchInvocation() returns false for
# /tmp/ paths (injection guard), but no WRITE_PATTERNS match "bash /tmp/..."
# → classify returns read (accepted false-negative at classify level; the hook
# enforces the /tmp/ rejection via isKnownDispatchInvocation separately).
assert_classify \
  "T3.50 bash /tmp/ dispatch path → read (no write pattern; false-neg accepted)" \
  "bash /tmp/bin/github-issues/issue-create-dispatch.sh" \
  "read"
