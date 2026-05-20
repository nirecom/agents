#!/usr/bin/env bash
# Usage: index.sh [--keywords-only] [--context-lines N]
set -uo pipefail

[[ -z "${AGENTS_CONFIG_DIR:-}" ]] && { echo "refactor-prompts: AGENTS_CONFIG_DIR not set" >&2; exit 2; }

KEYWORDS_ONLY=0
CONTEXT_LINES=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keywords-only) KEYWORDS_ONLY=1; shift ;;
    --context-lines) CONTEXT_LINES="$2"; shift 2 ;;
    *) echo "refactor-prompts: unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

KW=$(node "$SCRIPT_DIR/extract-keywords.js") || exit $?

if [[ "$KEYWORDS_ONLY" -eq 1 ]]; then
  printf '%s\n' "$KW"
  exit 0
fi

printf '%s' "$KW" | node "$SCRIPT_DIR/scan-prompts.js" --keywords - --context-lines "$CONTEXT_LINES"
