#!/usr/bin/env bash
# Heuristic detection of the "changed-contract-pinning-test" gap: for each
# changed file that may expose a contract (CLI stdout format, exported
# function signature, sentinel token text, etc.), check whether tests/**
# references that file's basename, and flag files with no match.
# This is a heuristic (basename string-match), not a proof of coverage —
# a match does not confirm the test actually pins the contract, and a miss
# does not confirm no test exists.
#
# Usage: detect-contract-pins.sh <changed-file> [more-files...]
#        printf '%s\n' file1 file2 | detect-contract-pins.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_CONFIG_DIR="${AGENTS_CONFIG_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
TESTS_DIR="$AGENTS_CONFIG_DIR/tests"

if [[ $# -gt 0 ]]; then
  FILES=("$@")
else
  FILES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && FILES+=("$line")
  done
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "Usage: detect-contract-pins.sh <changed-file> [more-files...]" >&2
  exit 2
fi

echo "## Contract-pin detection (heuristic — basename match, not proof)"
echo

UNPINNED=()
for f in "${FILES[@]}"; do
  base="$(basename -- "$f")"
  if [[ -d "$TESTS_DIR" ]] && grep -rlq -- "$base" "$TESTS_DIR" 2>/dev/null; then
    echo "- $f — referenced in tests/ (basename: $base)"
  else
    echo "- $f — NO reference found in tests/ (basename: $base)"
    UNPINNED+=("$f")
  fi
done

echo
if [[ ${#UNPINNED[@]} -eq 0 ]]; then
  echo "All changed files have at least one basename match under tests/. Heuristic only — verify manually that each match actually pins the contract rather than mentioning the file incidentally."
else
  echo "Flagged (${#UNPINNED[@]}): no test reference found. Heuristic only — verify manually before concluding no contract test exists:"
  for f in "${UNPINNED[@]}"; do
    echo "  - $f"
  done
fi
