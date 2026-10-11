#!/usr/bin/env bash
# skill-static.sh — #2527 3-6..3-8: release responsibilities moved between skills (static checks).
# Tests: skills/commit-push/SKILL.md, skills/worktree-end/SKILL.md, skills/deliver/SKILL.md, skills/get-release-approval/SKILL.md
# Tags: scope:issue-specific, workflow, release-phase, skill-static
# TL1: grep / line counts over the worktree copies (LOCAL, not the deployed ~/.claude copies).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): whether the model follows the moved steps at run time.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
CP_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/commit-push/SKILL.md"
WE_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/worktree-end/SKILL.md"
DL_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/deliver/SKILL.md"
GA_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/SKILL.md"
body() { if [ -f "$1" ]; then cat "$1"; else printf 'MISSING_FILE:%s' "$1"; fi; }
# longest_fence <file> — the most content lines inside any fenced code block.
longest_fence() {
  [ -f "$1" ] || { printf 'MISSING_FILE'; return; }
  awk '/^[[:space:]]*```/ { if (inb) { if (n > m) m = n; inb = 0 } else { inb = 1; n = 0 } next }
       inb { n++ } END { print m + 0 }' "$1"
}
lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '9999'; fi; }

case_begin "/commit-push: no CP-3, no /worktree-end hand-off" "skills/commit-push/SKILL.md"
cp="$(body "$CP_MD")"
check_contains "file present" "$cp" "commit"
check_not_contains "CP-3 removed" "$cp" "CP-3"
check_not_contains "no /worktree-end guidance" "$cp" "/worktree-end"
check_not_contains "AUTO_MERGE_PR exception removed" "$cp" "AUTO_MERGE_PR"
case_end

case_begin "/worktree-end: no USER_VERIFIED, no gh pr merge" "skills/worktree-end/SKILL.md"
we="$(body "$WE_MD")"
check_contains "file present" "$we" "worktree"
check_not_contains "USER_VERIFIED removed" "$we" "USER_VERIFIED"
check_not_contains "gh pr merge removed" "$we" "gh pr merge"
check_not_contains "AUTO_MERGE_PR removed" "$we" "AUTO_MERGE_PR"
case_end

case_begin "/deliver: merges are direct commands, not wrapped" "skills/deliver/SKILL.md"
dl="$(body "$DL_MD")"
check_contains "gh merge command names the PR number" "$dl" "gh pr merge <PR_NUMBER> --squash --delete-branch"
check_contains "glab merge command names the MR number" "$dl" "glab mr merge <PR_NUMBER> --squash --remove-source-branch"
check_not_contains "no number-less gh merge (would merge whatever PR the branch has)" "$dl" "gh pr merge --squash"
check_not_contains "no number-less glab merge" "$dl" "glab mr merge --squash"
wrapped="$( [ -f "$DL_MD" ] && grep -E 'gh pr merge|glab mr merge' "$DL_MD" | grep -cE 'bin/|scripts/' || true)"
check "no merge line routed through bin/ or scripts/" "${wrapped:-0}" "0"
case_end

case_begin "/deliver DL-3: PR number mismatch with the approval stops and re-runs /get-release-approval" "skills/deliver/SKILL.md"
dl3="$( [ -f "$DL_MD" ] && awk '/^DL-3\./ { inb = 1 } /^DL-3b\./ { exit } inb { print }' "$DL_MD" || printf 'MISSING_FILE')"
check_contains "DL-3 section present" "$dl3" "DL-3."
check_contains "DL-3 reads PR_NUMBER from pr-state" "$dl3" "PR_NUMBER="
check_contains "mismatch compares against the GA-3 approval" "$dl3" "differs from the PR number in the \`/get-release-approval\` GA-3 approval"
check_contains "mismatch stops and re-runs /get-release-approval" "$dl3" "stop and re-run \`/get-release-approval\` instead of merging"
mismatch_n="$(printf '%s\n' "$dl3" | grep -n 'differs from the PR number' | head -n 1 | cut -d: -f1)"
merge_n="$(printf '%s\n' "$dl3" | grep -n 'gh pr merge <PR_NUMBER>' | head -n 1 | cut -d: -f1)"
check "mismatch check precedes the merge command" "$([ -n "$mismatch_n" ] && [ -n "$merge_n" ] && [ "$mismatch_n" -lt "$merge_n" ] && echo ok || echo "mismatch=$mismatch_n merge=$merge_n")" "ok"
case_end

case_begin "new SKILL.md files stay within 100 lines" "skills/deliver/SKILL.md"
ga_n="$(lines_of "$GA_MD")"; dl_n="$(lines_of "$DL_MD")"
check "get-release-approval <= 100 lines" "$([ "$ga_n" -le 100 ] && echo ok || echo "$ga_n")" "ok"
check "deliver <= 100 lines" "$([ "$dl_n" -le 100 ] && echo ok || echo "$dl_n")" "ok"
case_end

case_begin "new SKILL.md files carry no code block of 3+ lines" "skills/get-release-approval/SKILL.md"
ga_f="$(longest_fence "$GA_MD")"; dl_f="$(longest_fence "$DL_MD")"
check "get-release-approval longest fence < 3" "$([ "$ga_f" != MISSING_FILE ] && [ "$ga_f" -lt 3 ] && echo ok || echo "$ga_f")" "ok"
check "deliver longest fence < 3" "$([ "$dl_f" != MISSING_FILE ] && [ "$dl_f" -lt 3 ] && echo ok || echo "$dl_f")" "ok"
case_end

case_begin "/deliver DL-3b: bootstrap-complete.sh gets the session id and documents Exit 4" "skills/deliver/SKILL.md"
dl3b="$( [ -f "$DL_MD" ] && awk '/^DL-3b\./ { inb = 1 } inb && /^[[:space:]]*$/ { exit } inb { print }' "$DL_MD" || printf 'MISSING_FILE')"
check_contains "DL-3b section present" "$dl3b" "bootstrap-complete.sh"
check_contains "4-arg invocation carries <session-id>" "$dl3b" 'bootstrap-complete.sh" "<WORKTREE_PATH>" "<BRANCH>" "<OWNER_REPO>" "<session-id>"'
check_not_contains "3-arg-only invocation absent" "$dl3b" '"<OWNER_REPO>"` as one standalone call'
check_contains "Exit 4 documented" "$dl3b" "Exit 4"
check_contains "Exit 4 means user_verification incomplete" "$dl3b" "user_verification is not complete"
check_contains "Exit 4 routes to /get-release-approval" "$dl3b" "/get-release-approval"
case_end

case_begin "/worktree-end WE-4: forge-neutral pr-state, only NONE is bootstrap" "skills/worktree-end/SKILL.md"
we4="$( [ -f "$WE_MD" ] && awk '/^### WE-4/ { inb = 1; print; next } inb && /^### / { exit } inb { print }' "$WE_MD" || printf 'MISSING_FILE')"
check_contains "WE-4 section present" "$we4" "### WE-4"
amr_ref='$AGENTS_MAIN_ROOT'
check_contains "WE-4 runs bin/workflow/pr-state" "$we4" "node \"$amr_ref/bin/workflow/pr-state\""
check_contains "PR_STATE=NONE -> bootstrap" "$we4" "\`PR_STATE=NONE\` → bootstrap"
check_contains "PR_STATE=UNKNOWN -> stop" "$we4" "\`PR_STATE=UNKNOWN\` (lookup failed) → stop"
check_contains "UNKNOWN never treated as bootstrap" "$we4" "never treat it as bootstrap"
check_not_contains "gh-only PR lookup gone from WE-4" "$we4" "gh pr view --json number"
check_not_contains "gh-only PR lookup gone from the whole skill" "$(body "$WE_MD")" "gh pr view --json number"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
