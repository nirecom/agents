#!/usr/bin/env bash
# confirm-primary.sh — reorder ISSUES[] after primary confirmation, append mutex marker
# Usage: confirm-primary.sh <selected_N> <prefill_path> <issue_N> [<issue_M>...]
#
# Outputs reordered issue numbers to stdout (primary first, one per line).
# Appends <!-- workflow-init: confirmed primary = N --> to prefill_path when it exists.
set -euo pipefail

SELECTED_N="$1"; shift
PREFILL_PATH="$1"; shift
ISSUES=("$@")

[[ "$SELECTED_N" =~ ^[0-9]+$ ]] || exit 1
[ "${#ISSUES[@]}" -ge 2 ] || exit 1

# Reorder: selected_N first, rest in original order
printf '%s\n' "$SELECTED_N"
for n in "${ISSUES[@]}"; do
    [ "$n" = "$SELECTED_N" ] && continue
    printf '%s\n' "$n"
done

# Append mutual-exclusion marker to prefill.md (Path B only — file may not exist for Path C)
if [ -f "$PREFILL_PATH" ]; then
    printf '\n<!-- workflow-init: confirmed primary = %s -->\n' "$SELECTED_N" >> "$PREFILL_PATH"
fi
