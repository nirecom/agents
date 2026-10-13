#!/usr/bin/env bash
# skill-static.sh — #2527 3-6..3-8 / 4-5: release responsibilities moved between skills (static checks).
# Tests: skills/commit-push/SKILL.md, skills/worktree-end/SKILL.md, skills/merge-to-main/SKILL.md, skills/get-release-approval/SKILL.md, .env.example
# Tags: scope:issue-specific, workflow, release-phase, skill-static
# TL1: grep / line counts over the worktree copies (LOCAL, not the deployed ~/.claude copies).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): whether the model follows the moved steps at run time.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
CP_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/commit-push/SKILL.md"
WE_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/worktree-end/SKILL.md"
MM_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/merge-to-main/SKILL.md"
GA_MD="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/SKILL.md"
ENV_EX="$_HELPERS_SCRIPT_CHECKOUT_ROOT/.env.example"
body() { if [ -f "$1" ]; then cat "$1"; else printf 'MISSING_FILE:%s' "$1"; fi; }
# longest_fence <file> — the most content lines inside any fenced code block.
longest_fence() {
  [ -f "$1" ] || { printf 'MISSING_FILE'; return; }
  awk '/^[[:space:]]*```/ { if (inb) { if (n > m) m = n; inb = 0 } else { inb = 1; n = 0 } next }
       inb { n++ } END { print m + 0 }' "$1"
}
lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '9999'; fi; }
# Decision G: the one-liner commit-push and worktree-end carry for AUTO_MERGE_PR=off.
AMP_ONE_LINER='AUTO_MERGE_PR=off (pull_request only): the human merges on the web; /merge-to-main never merges'

case_begin "/commit-push: no CP-3, no /worktree-end hand-off" "skills/commit-push/SKILL.md"
cp="$(body "$CP_MD")"
check_contains "file present" "$cp" "commit"
check_not_contains "CP-3 removed" "$cp" "CP-3"
check_not_contains "no /worktree-end guidance" "$cp" "/worktree-end"
check_contains "AUTO_MERGE_PR=off one-liner present" "$cp" "$AMP_ONE_LINER"
cp_amp="$(grep -c 'AUTO_MERGE_PR' "$CP_MD" 2>/dev/null || true)"
check "AUTO_MERGE_PR mentioned only by the one-liner" "${cp_amp:-0}" "1"
case_end

case_begin "/worktree-end: no USER_VERIFIED, no gh pr merge" "skills/worktree-end/SKILL.md"
we="$(body "$WE_MD")"
check_contains "file present" "$we" "worktree"
check_not_contains "USER_VERIFIED removed" "$we" "USER_VERIFIED"
check_not_contains "gh pr merge removed" "$we" "gh pr merge"
check_contains "AUTO_MERGE_PR=off one-liner present" "$we" "$AMP_ONE_LINER"
we_amp="$(grep -c 'AUTO_MERGE_PR' "$WE_MD" 2>/dev/null || true)"
check "AUTO_MERGE_PR mentioned only by the one-liner" "${we_amp:-0}" "1"
check_not_contains "no merge / wait-for-web-merge AskUserQuestion" "$we" "wait-for-web-merge"
case_end

case_begin "/merge-to-main: merges are direct commands, not wrapped" "skills/merge-to-main/SKILL.md"
mm="$(body "$MM_MD")"
check_contains "gh merge command names the PR number" "$mm" "gh pr merge <PR_NUMBER> --squash --delete-branch"
check_contains "glab merge command names the MR number" "$mm" "glab mr merge <PR_NUMBER> --squash --remove-source-branch"
check_not_contains "no number-less gh merge (would merge whatever PR the branch has)" "$mm" "gh pr merge --squash"
check_not_contains "no number-less glab merge" "$mm" "glab mr merge --squash"
wrapped="$( [ -f "$MM_MD" ] && grep -E 'gh pr merge|glab mr merge' "$MM_MD" | grep -cE 'bin/|scripts/' || true)"
check "no merge line routed through bin/ or scripts/" "${wrapped:-0}" "0"
check_contains "consults the release channel" "$mm" "release-channel"
check_not_contains "old /deliver name gone" "$mm" "/deliver"
check_not_contains "old DL- prefix gone" "$mm" "DL-"
case_end

case_begin "/merge-to-main MM-3: PR number mismatch with the approval stops and re-runs /get-release-approval" "skills/merge-to-main/SKILL.md"
mm3="$( [ -f "$MM_MD" ] && awk '/^MM-3\./ { inb = 1 } /^MM-3b\./ { exit } inb { print }' "$MM_MD" || printf 'MISSING_FILE')"
check_contains "MM-3 section present" "$mm3" "MM-3."
check_contains "MM-3 reads PR_NUMBER from pr-state" "$mm3" "PR_NUMBER="
check_contains "mismatch compares against the GA-3 approval" "$mm3" "differs from the PR number in the \`/get-release-approval\` GA-3 approval"
check_contains "mismatch stops and re-runs /get-release-approval" "$mm3" "stop and re-run \`/get-release-approval\` instead of merging"
mismatch_n="$(printf '%s\n' "$mm3" | grep -n 'differs from the PR number' | head -n 1 | cut -d: -f1)"
merge_n="$(printf '%s\n' "$mm3" | grep -n 'gh pr merge <PR_NUMBER>' | head -n 1 | cut -d: -f1)"
check "mismatch check precedes the merge command" "$([ -n "$mismatch_n" ] && [ -n "$merge_n" ] && [ "$mismatch_n" -lt "$merge_n" ] && echo ok || echo "mismatch=$mismatch_n merge=$merge_n")" "ok"
case_end

case_begin "new SKILL.md files stay within 100 lines" "skills/merge-to-main/SKILL.md"
ga_n="$(lines_of "$GA_MD")"; mm_n="$(lines_of "$MM_MD")"
check "get-release-approval <= 100 lines" "$([ "$ga_n" -le 100 ] && echo ok || echo "$ga_n")" "ok"
check "merge-to-main <= 100 lines" "$([ "$mm_n" -le 100 ] && echo ok || echo "$mm_n")" "ok"
case_end

case_begin "new SKILL.md files carry no code block of 3+ lines" "skills/get-release-approval/SKILL.md"
ga_f="$(longest_fence "$GA_MD")"; mm_f="$(longest_fence "$MM_MD")"
check "get-release-approval longest fence < 3" "$([ "$ga_f" != MISSING_FILE ] && [ "$ga_f" -lt 3 ] && echo ok || echo "$ga_f")" "ok"
check "merge-to-main longest fence < 3" "$([ "$mm_f" != MISSING_FILE ] && [ "$mm_f" -lt 3 ] && echo ok || echo "$mm_f")" "ok"
case_end

case_begin "/merge-to-main MM-3b: bootstrap-complete.sh gets the session id and documents Exit 4" "skills/merge-to-main/SKILL.md"
mm3b="$( [ -f "$MM_MD" ] && awk '/^MM-3b\./ { inb = 1 } inb && /^[[:space:]]*$/ { exit } inb { print }' "$MM_MD" || printf 'MISSING_FILE')"
check_contains "MM-3b section present" "$mm3b" "bootstrap-complete.sh"
check_contains "4-arg invocation carries <session-id>" "$mm3b" 'bootstrap-complete.sh" "<WORKTREE_PATH>" "<BRANCH>" "<OWNER_REPO>" "<session-id>"'
check_not_contains "3-arg-only invocation absent" "$mm3b" '"<OWNER_REPO>"` as one standalone call'
check_contains "Exit 4 documented" "$mm3b" "Exit 4"
check_contains "Exit 4 means user_verification incomplete" "$mm3b" "user_verification is not complete"
check_contains "Exit 4 routes to /get-release-approval" "$mm3b" "/get-release-approval"
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

case_begin "/get-release-approval: web-merge branch waits in the background without asking the human to report" "skills/get-release-approval/SKILL.md"
ga="$(body "$GA_MD")"
for kw in web_merge_pending web_merge_done web_merge_closed wait-web-merge.sh "WEB_MERGE=timeout"; do
  check_contains "GA names $kw" "$ga" "$kw"
done
bg_near="$( [ -f "$GA_MD" ] && grep -n 'wait-web-merge' "$GA_MD" | grep -c 'run_in_background' || true)"
check "run_in_background on a wait-web-merge line" "$([ "${bg_near:-0}" -ge 1 ] && echo ok || echo none)" "ok"
asks="$( [ -f "$GA_MD" ] && grep -ciE 'let me know|tell me when|report (back|the merge)|notify me' "$GA_MD" || true)"
check "no wording asking the human to report the merge" "${asks:-0}" "0"
to_lines="$( [ -f "$GA_MD" ] && grep -c 'WEB_MERGE=timeout' "$GA_MD" || true)"
check "WEB_MERGE=timeout reported on one line" "${to_lines:-0}" "1"
check_contains "GA-2: PREFLIGHT=web_merge_* raises no AskUserQuestion" "$ga" '`PREFLIGHT=web_merge_*` → raise no `AskUserQuestion`; follow that file'"'"'s "Web-merge channel" (the web merge is the only approval).'
case_end

case_begin ".env.example: decision-G AUTO_MERGE_PR comment block" ".env.example"
amp_n="$( [ -f "$ENV_EX" ] && grep -n '^AUTO_MERGE_PR=on$' "$ENV_EX" | head -n 1 | cut -d: -f1)"
check "AUTO_MERGE_PR=on present" "$([ -n "$amp_n" ] && echo ok || echo missing)" "ok"
if [ -n "$amp_n" ] && [ "$amp_n" -gt 3 ]; then
  g3="$(sed -n "$((amp_n - 3)),$((amp_n - 1))p" "$ENV_EX")"
else
  g3=""
fi
want_g3="# on (default): after you approve the USER_VERIFIED sentinel dialog, Claude merges the pull request and syncs your local repo.
# off: Claude never merges; you merge the pull request on GitHub and the workflow resumes automatically.
# ENFORCE_WORKTREE=on only (pull_request delivery); ignored when ENFORCE_WORKTREE=off."
check "three G lines immediately precede AUTO_MERGE_PR=on" "$g3" "$want_g3"
env_body="$(body "$ENV_EX")"
check_not_contains "old 'still asking for confirmation first' sentence gone" "$env_body" "still asking for confirmation first"
check_not_contains "old 'manual merge' sentence gone" "$env_body" "Set off to leave every pull request for a manual merge."
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
