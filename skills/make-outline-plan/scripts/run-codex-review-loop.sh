#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$AGENTS_CONFIG_DIR/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" intent)" || exit 4

args=(
  --format outline-plan
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/$SESSION_ID-outline.md"
  --cap 2 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$ACCEPTED_TRADEOFFS_FILE"
)
REPO_ROOT_VAL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$REPO_ROOT_VAL" ]]; then args+=(--repo-root "$REPO_ROOT_VAL"); fi
# CTX_CONCERNS_LOG is auto-generated from the ledger, never inherited (#2185): a
# stale parent value would leak an old carrier into this review. The CLI prints
# the carrier path only when it holds something to carry (rc 0); rc 3 is benign
# (nothing to carry), rc 5 is a real failure we warn about but do not fail on.
unset CTX_CONCERNS_LOG
clog_rc=0
CLOG_PATH="$("$AGENTS_CONFIG_DIR/bin/concern-ledger" render-concerns-log \
  --plans-dir "$PLANS_DIR" --session-id "$SESSION_ID" --format outline-plan)" || clog_rc=$?
if (( clog_rc == 0 )) && [[ -n "$CLOG_PATH" && -s "$CLOG_PATH" ]]; then
  export CTX_CONCERNS_LOG="$CLOG_PATH"
elif (( clog_rc != 0 && clog_rc != 3 )); then
  printf 'warning: concerns-log render failed (rc=%s); proceeding without CTX_CONCERNS_LOG\n' "$clog_rc" >&2
fi
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
RISK_FILE="$PLANS_DIR/$SESSION_ID-outline-risk-signal.txt"
if [[ -s "$RISK_FILE" ]]; then
  args+=(--risk-signal "$(head -n1 "$RISK_FILE")")
fi
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
exit "$RC"
