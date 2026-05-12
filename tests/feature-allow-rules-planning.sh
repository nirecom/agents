#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
SETTINGS="$REPO_ROOT/settings.json"

RULES=(
  "Bash(bash -c 'get-config-var *')"
  'Bash(get-config-var *)'
  'Read(**/.claude/plans/**)'
  'Bash(printf * >> */.claude/plans/*)'
)

NARROW_RULES=(
  'Write(~/.claude/plans/drafts/**)'
  'Edit(~/.claude/plans/drafts/**)'
  'Write(**/.claude/plans/drafts/**)'
  'Edit(**/.claude/plans/drafts/**)'
  'Write(**\\.claude\\plans\\drafts\\**)'
  'Edit(**\\.claude\\plans\\drafts\\**)'
)

# a) Each rule is present exactly once
for rule in "${RULES[@]}"; do
  count=$(grep -cF "$rule" "$SETTINGS" || true)
  [ "$count" -eq 1 ] || { echo "FAIL: rule appears $count times (expected 1): $rule"; exit 1; }
done

# a2) Each narrow rule is present exactly once
for rule in "${NARROW_RULES[@]}"; do
  count=$(grep -cF "$rule" "$SETTINGS" || true)
  [ "$count" -eq 1 ] || { echo "FAIL: narrow rule appears $count times (expected 1): $rule"; exit 1; }
done

# b) Regression: adjacent entries still present
for rule in 'Bash(doc-append *)' 'Write(**/tests/**)' 'Edit(**/tests/**)' \
            'Write(~/.claude/plans/drafts/**)' \
            'Edit(~/.claude/plans/drafts/**)' \
            'Write(**/.claude/plans/drafts/**)' \
            'Edit(**/.claude/plans/drafts/**)' \
            'Write(**\\.claude\\plans\\drafts\\**)' \
            'Edit(**\\.claude\\plans\\drafts\\**)'; do
  grep -qF "$rule" "$SETTINGS" || { echo "FAIL: missing regression entry: $rule"; exit 1; }
done

# c) Placement: rules appear between doc-append and Write(**/tests/**)
region=$(awk '/Bash\(doc-append \*\)/{p=1} p{print} /Write\(\*\*\/tests\/\*\*\)/{p=0}' "$SETTINGS")
for rule in "${RULES[@]}"; do
  echo "$region" | grep -qF "$rule" || { echo "FAIL: rule not in expected placement: $rule"; exit 1; }
done

# c2) Placement: narrow rules appear between Edit(**/tests/**) and WebSearch
region2=$(awk '/Edit\(\*\*\/tests\/\*\*\)/{p=1} p{print} /WebSearch/{p=0}' "$SETTINGS")
for rule in "${NARROW_RULES[@]}"; do
  echo "$region2" | grep -qF "$rule" || { echo "FAIL: narrow rule not in expected placement: $rule"; exit 1; }
done

# d) Negative: broad plans/** rules must have been removed
for rule in 'Write(**/.claude/plans/**)' 'Edit(**/.claude/plans/**)'; do
  if grep -qF "$rule" "$SETTINGS"; then
    echo "FAIL: broad rule must have been removed but still present: $rule"
    exit 1
  fi
done

echo "PASS: all assertions passed"
