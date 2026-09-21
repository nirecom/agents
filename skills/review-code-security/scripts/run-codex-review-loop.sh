#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
# Workflow session id (plan-artifact prefix), NOT the CC session UUID. The wsid has no
# bash bridge yet, so this stays a manual input box — see session-id-resolution.md.
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# #2276 S9-c re-invoke guard: after a terminal escalation the loop drops the round
# counter, so a bare re-run would restart at round 1 and hand the same unchanged diff a
# fresh 2+1 budget — a 4th review round through the back door. Line 1 = terminal rc,
# line 2 = the reviewed-diff fingerprint at that moment.
TERMINAL_FILE="${PLANS_DIR}/${SESSION_ID}-security-code-terminal.txt"
# Accept marker for residual HIGH after an exit 6 terminal: its presence authorizes the
# fingerprint-mismatch branch to clear the guard even when the prior terminal was exit 6.
EXIT6_ACCEPT_FILE="${PLANS_DIR}/${SESSION_ID}-security-code-exit6-accepted.txt"
# Dedicated code for "re-invoked after a terminal exit with the diff unchanged"; does not
# collide with bin/run-codex-review-loop's 0-7.
EXIT_REINVOKE_AFTER_TERMINAL=8
# exit 6 termination occurred, content changed, but residual HIGH not accepted → re-run blocked.
EXIT_EXIT6_UNACCEPTED=9

# Fingerprint of exactly what review-code-codex reviews: the committed tip plus every
# uncommitted change, including untracked file CONTENTS. Any real edit to the reviewed
# code (tracked or untracked) flips it; an untouched tree does not.
# Non-zero (empty stdout) when it cannot be computed (not a repo, git failure).
compute_diff_fingerprint() {
  local repo="$1" fp _uf
  fp="$( {
    git -C "$repo" rev-parse HEAD 2>/dev/null
    git -C "$repo" diff HEAD 2>/dev/null
    # Hash each untracked file's CONTENT (not its name) so editing an already-untracked
    # file changes the fingerprint. git hash-object accepts absolute paths directly.
    while IFS= read -r -d '' _uf; do
      git hash-object -- "${repo}/${_uf}" 2>/dev/null || true
    done < <(git -C "$repo" ls-files --others --exclude-standard -z 2>/dev/null)
  } | git -C "$repo" hash-object --stdin 2>/dev/null )" || return 1
  [[ -n "$fp" ]] || return 1
  printf '%s' "$fp"
}

REPO_ROOT_VAL="$(git rev-parse --show-toplevel 2>/dev/null || true)"

# The fallback re-run (--prestaged-report) JOINS the round the codex pass just opened
# (S8-d); it is never a fresh invocation, so the terminal guard must not see it.
PRESTAGED_RERUN=0
for a in "$@"; do
  if [[ "$a" == "--prestaged-report" ]]; then PRESTAGED_RERUN=1; break; fi
done

if [[ "$PRESTAGED_RERUN" -eq 0 && -f "$TERMINAL_FILE" ]]; then
  PREV_RC="$(sed -n '1p' "$TERMINAL_FILE" 2>/dev/null || true)"
  PREV_FP="$(sed -n '2p' "$TERMINAL_FILE" 2>/dev/null || true)"
  CUR_FP=""
  compute_diff_fingerprint "$REPO_ROOT_VAL" >/dev/null 2>&1 && CUR_FP="$(compute_diff_fingerprint "$REPO_ROOT_VAL")" || CUR_FP=""
  if [[ -z "$CUR_FP" || -z "$PREV_FP" ]]; then
    # fail-CLOSED: an uncomparable fingerprint is not evidence the diff changed.
    echo "[review-code-security] ERROR: previous security review ended with a terminal exit (code=${PREV_RC:-?}) and the reviewed-diff fingerprint could not be compared. Keeping the guard armed; edit and re-stage the code before re-running." >&2
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  if [[ "$CUR_FP" == "$PREV_FP" ]]; then
    echo "[review-code-security] ERROR: previous security review ended with a terminal exit (code=${PREV_RC:-?}) and the reviewed code is unchanged. Re-looping now would defeat the 2+1 round cap. Address the concerns and change the code, or accept the residual risk." >&2
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  if [ "${PREV_RC:-}" = "6" ] && [ ! -f "$EXIT6_ACCEPT_FILE" ]; then
    printf '[review-code-security] Code changed after an exit 6 terminal, but residual HIGH findings are not accepted.\n  Accept marker: %s\n  Create it: touch "%s"\n  Or: explicitly accept the residual HIGH via AskUserQuestion, then re-run.\n' "$EXIT6_ACCEPT_FILE" "$EXIT6_ACCEPT_FILE" >&2
    exit "$EXIT_EXIT6_UNACCEPTED"
  fi
  # Fingerprint mismatch = code was re-edited = a legitimate new review → auto-clear.
  rm -f "$TERMINAL_FILE"
fi

arm_terminal_guard() {
  local rc=$1 fp
  case "$rc" in
    # Non-success terminal codes only. exit 0 (APPROVED) must never arm. exit 1/5 are
    # round-continuing (S9-c). exit 3 opens the sanctioned scanner fallback re-run, not a
    # terminal — arming it would block that re-run. exit 4 (HALT) is a config/parse error
    # and does not drop the round counter; guard not needed. 2 (ESCALATE), 6
    # (HIGH_UNRESOLVED), and 7 (FINALIZE_FAILED) are terminal: settle_round_counter deletes
    # the counter on all three; without a guard, re-invocation opens a fresh 2+1 budget
    # on unchanged code (#2256 C4).
    2|6|7)
      fp=""
      fp="$(compute_diff_fingerprint "$REPO_ROOT_VAL")" || fp=""
      local _tmp
      _tmp="$(mktemp "${PLANS_DIR}/.sg-XXXXXX" 2>/dev/null)" || break
      printf '%s\n%s\n' "$rc" "$fp" > "$_tmp" || { rm -f "$_tmp"; break; }
      mv -f "$_tmp" "$TERMINAL_FILE" || rm -f "$_tmp"
      ;;
  esac
  return "$rc"
}

# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable. The precedence
# detail outline intent mirrors review-tests (CPR-ORTH): the reviewed code is downstream of
# all three settled decisions.
ACCEPTED_TRADEOFFS_FILE="$("$AGENTS_CONFIG_DIR/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" detail outline intent)" || exit 4

# security-code is a ref-kind (diff-based) format: the loop reads the working-tree diff, so no
# draft path is passed. --repo-root is the diff root and the MCP filesystem sandbox.
args=(
  --format security-code
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --cap 2 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$ACCEPTED_TRADEOFFS_FILE"
)
if [[ -n "$REPO_ROOT_VAL" ]]; then args+=(--repo-root "$REPO_ROOT_VAL"); fi
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done

# Extra flags (--prestaged-report / --prestaged-producer / --prestaged-exec on the
# security-scanner fallback re-run) are forwarded verbatim; the loop owns their semantics.
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" "$@" || RC=$?
arm_terminal_guard "$RC" || true
exit "$RC"
