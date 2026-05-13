#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
SETTINGS="$REPO_ROOT/settings.json"

RULES=(
  "Bash(bash -c 'get-config-var *')"
  'Bash(get-config-var *)'
)

# a) Each rule is present exactly once
for rule in "${RULES[@]}"; do
  count=$(grep -cF "$rule" "$SETTINGS" || true)
  [ "$count" -eq 1 ] || { echo "FAIL: rule appears $count times (expected 1): $rule"; exit 1; }
done

# b) Regression: adjacent entries still present
for rule in 'Bash(doc-append *)' 'Write(**/tests/**)' 'Edit(**/tests/**)'; do
  grep -qF "$rule" "$SETTINGS" || { echo "FAIL: missing regression entry: $rule"; exit 1; }
done

# c) Negative: no plans-path allow rules needed — ~/.workflow-plans/ is not a protected path
# Old .claude/plans rules must be absent; no new .workflow-plans rules should be added
for rule in \
  'Read(**/.claude/plans/**)' \
  'Bash(printf * >> */.claude/plans/*)' \
  'Read(**/.workflow-plans/**)' \
  'Bash(printf * >> */.workflow-plans/*)' \
  'Write(**/.workflow-plans/**)' \
  'Edit(**/.workflow-plans/**)'; do
  if grep -qF "$rule" "$SETTINGS"; then
    echo "FAIL: plans allow rule must be absent but found: $rule"
    exit 1
  fi
done

echo "PASS: all assertions passed"
