#!/usr/bin/env bash
# review-scope-header-targets.sh — the staged-test → `Tests:` header map for the #2327 re-review
# delta (bin/lib/review-scope-header-targets.js is the only caller).
# Usage: review-scope-header-targets.sh <root>  — stdin: NUL-terminated repo-relative paths, each
# read as <root>/<rel>. Stdout, one record per input path in input order:
# <rel>\0<n>\0<tok1>\0…<tokn>\0 — tokens passing tfm_token_format_ok only (bin/lib/test-frontmatter-fix.sh).
# Exit: 0 ok; 2 usage (<root> missing or not a directory); 3 library or registry unreadable;
# 4 an input file is unreadable (path on stderr).
# No -e: the sourced SSOT helpers are written for callers that check return codes themselves.
set -uo pipefail

RSHT_ROOT="${1:-}"
if [[ -z "$RSHT_ROOT" || ! -d "$RSHT_ROOT" ]]; then
  echo "review-scope-header-targets: usage: review-scope-header-targets.sh <root> (an existing directory)" >&2
  exit 2
fi

RSHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-frontmatter-fix.sh
source "$RSHT_DIR/lib/test-frontmatter-fix.sh" || {
  echo "review-scope-header-targets: cannot load bin/lib/test-frontmatter-fix.sh or the test-language registry" >&2
  exit 3
}

while IFS= read -r -d '' rel; do
  file="$RSHT_ROOT/$rel"
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf 'review-scope-header-targets: cannot read input file: %s\n' "$rel" >&2
    exit 4
  fi
  tfm_parse_tests_line "$file"
  kept=()
  for tok in "${TFM_TOKENS[@]+"${TFM_TOKENS[@]}"}"; do
    tfm_token_format_ok "$tok" && kept+=("$tok")
  done
  printf '%s\0%s\0' "$rel" "${#kept[@]}"
  for tok in "${kept[@]+"${kept[@]}"}"; do
    printf '%s\0' "$tok"
  done
done

exit 0
