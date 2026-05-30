#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

args=(
  --format outline-plan
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/drafts/$SESSION_ID-outline-draft.md"
  --cap 1 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$PLANS_DIR/$SESSION_ID-intent.md"
)
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
exec "$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}"
