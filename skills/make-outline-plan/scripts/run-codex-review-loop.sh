#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

ROUND_FILE="${PLANS_DIR}/drafts/${SESSION_ID}-outline-plan-round-number.txt"
mkdir -p "$(dirname "$ROUND_FILE")"
if [[ -f "$ROUND_FILE" ]]; then
  ROUND_NUMBER=$(( $(<"$ROUND_FILE") + 1 ))
else
  ROUND_NUMBER=1
fi
printf '%s\n' "$ROUND_NUMBER" > "$ROUND_FILE"

cleanup_counter() {
  local rc=$1
  case "$rc" in
    0|2) rm -f "$ROUND_FILE" ;;
  esac
  return "$rc"
}

args=(
  --format outline-plan
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/drafts/$SESSION_ID-outline-draft.md"
  --cap 1 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$PLANS_DIR/$SESSION_ID-intent.md"
  --round "$ROUND_NUMBER"
)
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
cleanup_counter "$RC" || true
exit "$RC"
