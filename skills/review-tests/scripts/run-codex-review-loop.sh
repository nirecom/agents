#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

ROUND_FILE="${PLANS_DIR}/${SESSION_ID}-test-review-round-number.txt"
if [[ -f "$ROUND_FILE" ]]; then
  ROUND_NUMBER=$(( $(<"$ROUND_FILE") + 1 ))
else
  ROUND_NUMBER=1
fi
printf '%s\n' "$ROUND_NUMBER" > "$ROUND_FILE"

cleanup_counter() {
  local rc=$1
  case "$rc" in
    0|1|2|4) rm -f "$ROUND_FILE" ;;
    # single-round terminal format: exit 1 is terminal (no re-loop), so clear too.
    # exit 5 (AUTO_EXTEND) does not occur here (MAX_EXTENSIONS=0).
  esac
  return "$rc"
}

args=(
  --format test-review
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/$SESSION_ID-test-review.md"
  --cap 1 --max-extensions 0 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$PLANS_DIR/$SESSION_ID-outline.md"
  --round "$ROUND_NUMBER"
)
REPO_ROOT_VAL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$REPO_ROOT_VAL" ]]; then args+=(--repo-root "$REPO_ROOT_VAL"); fi
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
TEST_DESIGN="$AGENTS_CONFIG_DIR/skills/_shared/test-design.md"
if [[ -s "$TEST_DESIGN" ]]; then args+=(--context "$TEST_DESIGN"); fi
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
cleanup_counter "$RC" || true
exit "$RC"
