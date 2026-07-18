#!/usr/bin/env bash
# Discover and run every RUN_E2E-gated test file, then report a pass/fail summary.
# Requires RUN_E2E=on in the agents config (or via env) and claude CLI on PATH.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || { echo "ERROR: get-config-var not found" >&2; exit 1; }
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && {
  echo "ERROR: RUN_E2E is off — set RUN_E2E=on in agents config before running the matrix." >&2
  exit 1
}
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0
FAILED_FILES=()

while IFS= read -r -d '' f; do
  if grep -q 'get-config-var.*--is-off RUN_E2E' "$f" 2>/dev/null; then
    set +e
    bash "$f"
    RC=$?
    set -e
    if [ "$RC" -eq 0 ]; then
      PASS=$((PASS+1))
    elif [ "$RC" -eq 77 ]; then
      SKIP=$((SKIP+1))
    else
      FAIL=$((FAIL+1))
      FAILED_FILES+=("$f")
    fi
  fi
done < <(find "$AGENTS_DIR/tests" -maxdepth 2 -name '*.sh' -print0 | sort -z)

echo ""
echo "Matrix results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
  echo "Failed:"
  printf '  %s\n' "${FAILED_FILES[@]}"
  exit 1
fi
exit 0
