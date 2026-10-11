#!/usr/bin/env bash
# get-release-approval GA-2: release preflight before the USER_VERIFIED sentinel (#2527).
# Usage: bash preflight.sh --session <sid> [--repo <dir>]
# Stdout, in order: RUN_TL4=ON|OFF|ERROR, GATE_RC=<rc>, the check-verification-gate.sh
#   CATEGORY lines, PR_NUMBER=<n>, then PREFLIGHT=ok|blocked|merged_on_web and PREFLIGHT_REASON=<text>.
# PR mergeability (pull_request path only): CLEAN -> ok, MERGED -> merged_on_web, anything else -> blocked.
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
  printf 'PR_NUMBER=%s\nPREFLIGHT=%s\nPREFLIGHT_REASON=%s\n' "${PR_NUMBER:-}" "$1" "$2"
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

# Empty-remote bootstrap: no PR can exist; /deliver pushes after USER_VERIFIED. A read failure falls through.
PUSH_DECISION="$(node -e 'try{const s=require(process.argv[1]).readState(process.argv[2]);process.stdout.write(String((s&&s.steps&&s.steps.push_branch&&s.steps.push_branch.decision)||""))}catch(_){}' "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io" "$SID" 2>/dev/null || true)"
[[ "$PUSH_DECISION" != "bootstrap" ]] || finish ok "push_branch recorded a bootstrap push to an empty remote — no pull request to check"

FORGE="$(node "$SCRIPT_CHECKOUT_ROOT/bin/detect-forge-type" --repo-dir "$TARGET_CHECKOUT_ROOT" --field type 2>/dev/null || true)"
PR_NUMBER=""
STATE=""
MERGE=""
if [[ "$FORGE" == "gitlab" ]]; then
  JSON="$(cd "$TARGET_CHECKOUT_ROOT" && glab mr view --output json 2>/dev/null || true)"
  [[ -n "$JSON" ]] || finish blocked "no merge request for the current branch — run /commit-push first"
  PARSED="$(printf '%s' "$JSON" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const j=JSON.parse(s);const st=String(j.state||"").toLowerCase();const m=String(j.detailed_merge_status||j.merge_status||"");const draft=j.draft===true||j.work_in_progress===true;const map={mergeable:"CLEAN",can_be_merged:"CLEAN",conflict:"DIRTY",cannot_be_merged:"DIRTY",need_rebase:"BEHIND",draft_status:"DRAFT",ci_must_pass:"BLOCKED",ci_still_running:"BLOCKED",not_approved:"BLOCKED",discussions_not_resolved:"BLOCKED",blocked_status:"BLOCKED",external_status_checks:"BLOCKED",jira_association_missing:"BLOCKED",requested_changes:"BLOCKED"};process.stdout.write([j.iid||"",st==="merged"?"MERGED":st==="opened"?"OPEN":st.toUpperCase(),draft?"DRAFT":(map[m]||m.toUpperCase())].join(" "))}catch(_){process.stdout.write("")}})')"
else
  PARSED="$(cd "$TARGET_CHECKOUT_ROOT" && gh pr view --json number,state,mergeStateStatus --jq '"\(.number) \(.state) \(.mergeStateStatus)"' 2>/dev/null || true)"
fi
[[ -n "$PARSED" ]] || finish blocked "no pull request for the current branch — run /commit-push first"
read -r PR_NUMBER STATE MERGE <<<"$PARSED"

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
