#!/bin/bash
set -euo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# #2276 CPR-ORTH with review-code-security/review-tests: after a terminal exit
# (2/6) the round counter is deleted; a bare re-run would restart at round 1 and
# hand the same unchanged plan a fresh 2+1 budget, bypassing the shared cap.
# The terminal and the exit-6 accept marker live in <sid>.control/ (#2434).
# shellcheck source=bin/lib/codex-review-loop/review-wrapper-control.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/lib/codex-review-loop/review-wrapper-control.sh" || exit 4
# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$SCRIPT_CHECKOUT_ROOT/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" outline intent)" || exit 4
rwc_resolve security-plan review-plan-security

DRAFT_FILE="${PLANS_DIR}/${SESSION_ID}-detail.md"

# Fingerprint the draft plan file by its git object SHA (content hash). Any real
# edit to the plan flips it; an untouched file does not.
compute_draft_fingerprint() {
  local draft="$1" fp
  [[ -f "$draft" ]] || return 1
  fp="$(git hash-object -- "$draft" 2>/dev/null)" || return 1
  [[ -n "$fp" ]] || return 1
  printf '%s' "$fp"
}

CUR_FP="$(compute_draft_fingerprint "$DRAFT_FILE")" || CUR_FP=""
TG_RC=0
rwc_check_terminal review-plan-security "$CUR_FP" review-plan-security-exit6-accepted.txt security-plan || TG_RC=$?
(( TG_RC == 0 )) || exit "$TG_RC"

arm_terminal_guard() {
  local rc=$1 fp
  case "$rc" in
    # exit 7 (FINALIZE_FAILED) drops the round counter via settle_round_counter's
    # rollback path (REDUCE_COMMITTED=true -> _srn_terminate) exactly like exits 2
    # and 6; arm it so re-invocation on unchanged code is blocked (#2256 C4).
    2|6|7)
      fp="$(compute_draft_fingerprint "$DRAFT_FILE")" || fp=""
      rwc_arm_terminal "$rc" "$fp"
      ;;
  esac
  return "$rc"
}

args=(
  --format security-plan
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$DRAFT_FILE"
  --cap 2 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$ACCEPTED_TRADEOFFS_FILE"
  --class-members "$PLANS_DIR/$SESSION_ID-intent.md"
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
  --plans-dir "$PLANS_DIR" --session-id "$SESSION_ID" --format security-plan)" || clog_rc=$?
if (( clog_rc == 0 )) && [[ -n "$CLOG_PATH" && -s "$CLOG_PATH" ]]; then
  export CTX_CONCERNS_LOG="$CLOG_PATH"
elif (( clog_rc != 0 && clog_rc != 3 )); then
  printf 'warning: concerns-log render failed (rc=%s); proceeding without CTX_CONCERNS_LOG\n' "$clog_rc" >&2
fi
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
# No risk signal: security-plan has no writer for one, and reading one would let
# a model-written file turn HIGH_UNRESOLVED into ESCALATE past the exit-6 accept (#2434).
RC=0
"$SCRIPT_CHECKOUT_ROOT/bin/run-codex-review-loop" "${args[@]}" || RC=$?
arm_terminal_guard "$RC" || true
exit "$RC"
