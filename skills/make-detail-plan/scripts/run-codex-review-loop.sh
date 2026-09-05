#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$AGENTS_CONFIG_DIR/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" outline intent)" || exit 4

args=(
  --format detail-plan
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/$SESSION_ID-detail.md"
  --cap 2 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$ACCEPTED_TRADEOFFS_FILE"
)
REPO_ROOT_VAL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$REPO_ROOT_VAL" ]]; then args+=(--repo-root "$REPO_ROOT_VAL"); fi
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
RISK_FILE="$PLANS_DIR/$SESSION_ID-detail-risk-signal.txt"
if [[ -s "$RISK_FILE" ]]; then
  args+=(--risk-signal "$(head -n1 "$RISK_FILE")")
fi
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
exit "$RC"
