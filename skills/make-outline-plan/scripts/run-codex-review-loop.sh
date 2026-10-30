#!/bin/bash
set -euo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# shellcheck source=bin/lib/codex-review-loop/review-wrapper-control.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/lib/codex-review-loop/review-wrapper-control.sh" || exit 4
# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$SCRIPT_CHECKOUT_ROOT/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" intent)" || exit 4
rwc_resolve outline-plan make-outline-plan
# Plans are named after first_session_id (#2748); PLANS_DIR keeps its spelling, only the basename
# comes from the CLI. An unresolvable plan path halts (4) instead of falling back to the own sid.
plan_file() {
  local p
  p="$(node "$SCRIPT_CHECKOUT_ROOT/bin/plan-artifact-path" --stage "$1" --session "$SESSION_ID" --plans-dir "$PLANS_DIR" 2>/dev/null)" || return 1
  [[ "${p##*[/\\]}" == *"-$1.md" ]] || return 1
  printf '%s/%s' "$PLANS_DIR" "${p##*[/\\]}"
}
INTENT_FILE="$(plan_file intent)" || { echo "make-outline-plan: cannot resolve the intent path" >&2; exit 4; }
DRAFT_FILE="$(plan_file outline)" || { echo "make-outline-plan: cannot resolve the outline path" >&2; exit 4; }
CUR_FP="$(git hash-object -- "$DRAFT_FILE" 2>/dev/null || true)"
TG_RC=0
rwc_check_terminal make-outline-plan "$CUR_FP" || TG_RC=$?
(( TG_RC == 0 )) || exit "$TG_RC"

args=(
  --format outline-plan
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$DRAFT_FILE"
  --cap 2 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$ACCEPTED_TRADEOFFS_FILE"
  --class-members "$INTENT_FILE"
)
REPO_ROOT_VAL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$REPO_ROOT_VAL" ]]; then args+=(--repo-root "$REPO_ROOT_VAL"); fi
# CTX_CONCERNS_LOG is auto-generated from the ledger, never inherited (#2185): a
# stale parent value would leak an old carrier into this review. The CLI prints
# the carrier path only when it holds something to carry (rc 0); rc 3 is benign
# (nothing to carry), rc 5 is a real failure we warn about but do not fail on.
unset CTX_CONCERNS_LOG
clog_rc=0
CLOG_PATH="$("$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger" render-concerns-log \
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
RISK_FILE="$(sp_control_dir "$SESSION_ID" outline-risk-signal.txt)" || exit 4
if [[ -s "$RISK_FILE" ]]; then
  args+=(--risk-signal "$(head -n1 "$RISK_FILE")")
fi
RC=0
"$SCRIPT_CHECKOUT_ROOT/bin/run-codex-review-loop" "${args[@]}" || RC=$?
exit "$RC"
