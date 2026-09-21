#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# #2276 CPR-ORTH with review-code-security/review-tests: after a terminal exit
# (2/6) the round counter is deleted; a bare re-run would restart at round 1 and
# hand the same unchanged plan a fresh 2+1 budget, bypassing the shared cap.
TERMINAL_FILE="${PLANS_DIR}/${SESSION_ID}-security-plan-terminal.txt"
EXIT_REINVOKE_AFTER_TERMINAL=8

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

if [[ -f "$TERMINAL_FILE" ]]; then
  PREV_RC="$(sed -n '1p' "$TERMINAL_FILE" 2>/dev/null || true)"
  PREV_FP="$(sed -n '2p' "$TERMINAL_FILE" 2>/dev/null || true)"
  CUR_FP=""
  CUR_FP="$(compute_draft_fingerprint "$DRAFT_FILE")" || CUR_FP=""
  if [[ -z "$CUR_FP" || -z "$PREV_FP" ]]; then
    echo "[review-plan-security] ERROR: previous security review ended with a terminal exit (code=${PREV_RC:-?}) and the reviewed-plan fingerprint could not be compared. Keeping the guard armed; edit and re-stage the plan before re-running." >&2
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  if [[ "$CUR_FP" == "$PREV_FP" ]]; then
    echo "[review-plan-security] ERROR: previous security review ended with a terminal exit (code=${PREV_RC:-?}) and the reviewed plan is unchanged. Re-looping now would defeat the 2+1 round cap. Address the concerns and change the plan, or accept the residual risk." >&2
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  rm -f "$TERMINAL_FILE"
fi

arm_terminal_guard() {
  local rc=$1 fp
  case "$rc" in
    # exit 7 (FINALIZE_FAILED) drops the round counter via settle_round_counter's
    # rollback path (REDUCE_COMMITTED=true -> _srn_terminate) exactly like exits 2
    # and 6; arm it so re-invocation on unchanged code is blocked (#2256 C4).
    2|6|7)
      fp=""
      fp="$(compute_draft_fingerprint "$DRAFT_FILE")" || fp=""
      local _tmp
      _tmp="$(mktemp "${PLANS_DIR}/.sg-XXXXXX" 2>/dev/null)" || break
      printf '%s\n%s\n' "$rc" "$fp" > "$_tmp" || { rm -f "$_tmp"; break; }
      mv -f "$_tmp" "$TERMINAL_FILE" || rm -f "$_tmp"
      ;;
  esac
  return "$rc"
}

# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$AGENTS_CONFIG_DIR/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" outline intent)" || exit 4

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
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
RISK_FILE="$PLANS_DIR/$SESSION_ID-security-plan-risk-signal.txt"
if [[ -s "$RISK_FILE" ]]; then
  args+=(--risk-signal "$(head -n1 "$RISK_FILE")")
fi
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
arm_terminal_guard "$RC" || true
exit "$RC"
