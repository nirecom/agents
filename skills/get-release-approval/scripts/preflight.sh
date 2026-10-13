#!/usr/bin/env bash
# get-release-approval GA-2: release preflight before the USER_VERIFIED sentinel (#2527).
# Usage: bash preflight.sh --session <sid> [--repo <dir>]
# Stdout, in order: RUN_TL4=ON|OFF|ERROR, GATE_RC=<rc>, the check-verification-gate.sh
#   CATEGORY lines, [PR_URL=<url>,] PR_NUMBER=<n>, then PREFLIGHT=<verdict> and PREFLIGHT_REASON=<text>.
# PR mergeability (pull_request path only): CLEAN -> ok, MERGED -> merged_on_web, anything else -> blocked.
# Web-merge channel (AUTO_MERGE_PR=off): MERGED -> web_merge_done, CLOSED -> web_merge_closed,
#   OPEN + CLEAN -> web_merge_pending (with PR_URL); anything not ready -> web_merge_blocked (same texts).
# A pull_request session whose push_branch recorded decision=bootstrap (empty remote) is ok with no PR check.
# Exit: 0 whenever a PREFLIGHT line was printed; 1 usage error.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SID=""
TARGET_CHECKOUT_ROOT="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SID="${2:?--session requires a value}"; shift 2 ;;
    --repo) TARGET_CHECKOUT_ROOT="${2:?--repo requires a value}"; shift 2 ;;
    *) printf 'preflight: unknown argument %s\n' "$1" >&2; exit 1 ;;
  esac
done
[[ -n "$SID" ]] || { printf 'Usage: preflight.sh --session <sid> [--repo <dir>]\n' >&2; exit 1; }

finish() {
  local verdict="$1"
  # The web-merge channel never raises an ask: its not-ready verdict carries the web_merge_ prefix too.
  if [[ "${CHANNEL:-}" == "web-merge" && "$verdict" == "blocked" ]]; then verdict="web_merge_blocked"; fi
  printf 'PR_NUMBER=%s\nPREFLIGHT=%s\nPREFLIGHT_REASON=%s\n' "${PR_NUMBER:-}" "$verdict" "$2"
  exit 0
}

# RUN_TL4 readiness; a failed read is ERROR, which the caller treats as on (fail-safe).
TL4="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/confirm-off" RUN_TL4 off 2>/dev/null || true)"
case "$TL4" in ON|OFF) ;; *) TL4="ERROR" ;; esac
printf 'RUN_TL4=%s\n' "$TL4"

# Risk-category classifier; the caller decides on asks from these lines and RUN_TL4.
GATE_RC=0
GATE_OUT="$(cd "$TARGET_CHECKOUT_ROOT" && bash "$SCRIPT_CHECKOUT_ROOT/bin/check-verification-gate.sh")" || GATE_RC=$?
printf 'GATE_RC=%s\n' "$GATE_RC"
if [[ -n "$GATE_OUT" ]]; then printf '%s\n' "$GATE_OUT"; fi

# Fail closed: only an exact known route line decides; a CLI failure or anything else blocks.
ROUTE_LINE="$(node "$SCRIPT_CHECKOUT_ROOT/bin/session-close-detect-route.js" --session "$SID" 2>/dev/null)" \
  || finish blocked "delivery path could not be resolved (route CLI failed)"
case "$ROUTE_LINE" in
  ROUTE=direct|ROUTE=wf-meta) finish ok "delivery path ${ROUTE_LINE#ROUTE=} — no pull request to check" ;;
  ROUTE=pull_request) ;;
  *) finish blocked "delivery path could not be resolved (route CLI printed '${ROUTE_LINE}')" ;;
esac

# Empty-remote bootstrap: no PR can exist; /merge-to-main pushes after USER_VERIFIED. A read failure falls through.
PUSH_DECISION="$(node -e 'try{const s=require(process.argv[1]).readState(process.argv[2]);process.stdout.write(String((s&&s.steps&&s.steps.push_branch&&s.steps.push_branch.decision)||""))}catch(_){}' "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io" "$SID" 2>/dev/null || true)"
[[ "$PUSH_DECISION" != "bootstrap" ]] || finish ok "push_branch recorded a bootstrap push to an empty remote — no pull request to check"

# Release channel (4-5): AUTO_MERGE_PR=off on pull_request means the human merges on the web.
# A read failure is the dialog channel, which never moves the release decision to the web.
CHANNEL_OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/release-channel" --session "$SID" 2>/dev/null || true)"
CHANNEL="user-verified-dialog"
[[ "$CHANNEL_OUT" != *"CHANNEL=web-merge"* ]] || CHANNEL="web-merge"

# One forge read; the GitLab -> gh-vocabulary mapping lives in hooks/lib/forge/merge-state.js.
PR_OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/pr-state" --repo "$TARGET_CHECKOUT_ROOT" --merge-state 2>/dev/null || true)"
pr_field() { printf '%s\n' "$PR_OUT" | sed -n "s/^$1=//p" | head -n 1; }
STATE="$(pr_field PR_STATE)"
PR_NUMBER="$(pr_field PR_NUMBER)"
MERGE="$(pr_field PR_MERGE_STATE)"
PR_URL="$(pr_field PR_URL)"
if [[ "$STATE" == "NONE" ]]; then
  FORGE="$(node "$SCRIPT_CHECKOUT_ROOT/bin/detect-forge-type" --repo-dir "$TARGET_CHECKOUT_ROOT" --field type 2>/dev/null || true)"
  [[ "$FORGE" != "gitlab" ]] || finish blocked "no merge request for the current branch — run /commit-push first"
fi
case "$STATE" in
  OPEN|MERGED|CLOSED) ;;
  *) PR_NUMBER=""; finish blocked "no pull request for the current branch — run /commit-push first" ;;
esac

if [[ "$CHANNEL" == "web-merge" ]]; then
  case "$STATE" in
    MERGED) finish web_merge_done "PR #$PR_NUMBER was merged on the web — run next-step to record merge_to_main" ;;
    CLOSED) finish web_merge_closed "PR #$PR_NUMBER was closed without merge — reopen it or re-run /commit-push" ;;
  esac
  if [[ "$MERGE" == "CLEAN" ]]; then
    printf 'PR_URL=%s\n' "$PR_URL"
    finish web_merge_pending "PR #$PR_NUMBER is open and mergeable (CLEAN) — the human merges it on the web"
  fi
fi

case "$STATE" in
  MERGED) finish merged_on_web "PR #$PR_NUMBER was already merged outside this session" ;;
  OPEN) ;;
  *) finish blocked "PR #$PR_NUMBER is ${STATE:-UNKNOWN}, not OPEN" ;;
esac
case "$MERGE" in
  CLEAN) finish ok "PR #$PR_NUMBER is open and mergeable (CLEAN)" ;;
  BEHIND) finish blocked "PR #$PR_NUMBER is BEHIND the base branch — rebase or update the branch, then re-run" ;;
  DIRTY) finish blocked "PR #$PR_NUMBER has merge conflicts (DIRTY) — rebase and resolve, then re-run" ;;
  BLOCKED|UNSTABLE) finish blocked "PR #$PR_NUMBER is $MERGE — wait for required checks or reviews, then re-run" ;;
  DRAFT) finish blocked "PR #$PR_NUMBER is a draft — mark it ready for review, then re-run" ;;
  *) finish blocked "PR #$PR_NUMBER mergeability is ${MERGE:-UNKNOWN} — wait for the forge to compute it, then re-run" ;;
esac
