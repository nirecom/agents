#!/bin/bash
# SSOT for the test-reviewer input-contract violation (#1455): a line-start
# `INPUT_ERROR <path>` in the reviewer output. Used by run-codex-review-loop.sh
# and by the CC fallback in skills/review-tests/SKILL.md RT-3 (symmetric).
# Usage: detect-input-error.sh <reviewer-output-file>
# Exit: 4 = INPUT_ERROR line found (printed on stderr), 0 = none, 2 = unreadable/usage.
set -euo pipefail

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "detect-input-error.sh: usage: detect-input-error.sh <reviewer-output-file>" >&2
  exit 2
fi
file="$1"
if [[ ! -f "$file" || ! -r "$file" ]]; then
  echo "detect-input-error.sh: cannot read reviewer output: $file" >&2
  exit 2
fi

found=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" == "INPUT_ERROR "* ]]; then
    printf '%s\n' "$line" >&2
    found=1
  fi
done < "$file"

if (( found == 1 )); then
  exit 4
fi
exit 0
