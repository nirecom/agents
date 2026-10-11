#!/usr/bin/env bash
# Usage: index.sh [--keywords-only] [--context-lines N] [--target-checkout-root DIR]
set -uo pipefail

KEYWORDS_ONLY=0
CONTEXT_LINES=3
TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keywords-only) KEYWORDS_ONLY=1; shift ;;
    --context-lines) [[ $# -ge 2 ]] || { echo "refactor-prompts: $1 needs a value" >&2; exit 2; }; CONTEXT_LINES="$2"; shift 2 ;;
    --target-checkout-root) [[ $# -ge 2 ]] || { echo "refactor-prompts: $1 needs a value" >&2; exit 2; }; TARGET_ARGS=(--target-checkout-root "$2"); shift 2 ;;
    *) echo "refactor-prompts: unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

KW=$(node "$SCRIPT_DIR/extract-keywords.js" "${TARGET_ARGS[@]}") || exit $?

if [[ "$KEYWORDS_ONLY" -eq 1 ]]; then
  printf '%s\n' "$KW"
  exit 0
fi

printf '%s' "$KW" | node "$SCRIPT_DIR/scan-prompts.js" --keywords - --context-lines "$CONTEXT_LINES" "${TARGET_ARGS[@]}"
