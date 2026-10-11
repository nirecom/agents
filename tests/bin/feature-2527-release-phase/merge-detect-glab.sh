#!/usr/bin/env bash
# merge-detect-glab.sh — #2527 3-2/3-7: `glab mr merge` is a merge to protected, gated and reset like gh.
# Tests: hooks/lib/merge-detect.js, hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: scope:issue-specific, workflow, release-phase, merge-gate
# TL2: unit calls to merge-detect + workflow-gate / workflow-mark fed Bash payloads (v4 state,
# readable by today's code, so the gh baseline cases stay green).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a real glab merge against a GitLab host.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: hook-registration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup

# detect <command> — "<hit>|<kind>" from isMergeToProtectedCommand.
detect() {
  run_with_timeout 30 node -e '
    const m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/lib/merge-detect.js");
    const r = m.isMergeToProtectedCommand(process.argv[1]);
    console.log(r.hit + "|" + r.kind);
  ' "$1" 2>&1
}

# assert_eq <name> <want> <got> — table-driven assertion (parser-regex-tests.md form).
assert_eq() { check "$1" "$3" "$2"; }

# Rows mirror today's gh-pr-merge semantics for glab-mr-merge: `merge` must be a whole word
# (mergeable / merged-list are not merges), quoted or commented text is not a command, and a
# merge in any chained or wrapped (rtk / env) segment is detected. Flags (and their values) may
# sit before or between the path words (global `-R x` hits); a bare word there ends the path.
# Mutation Probe: no probe-able `const NAME = /re/;` (hasSubcommandPath is token logic), so the
# kill check is the near-miss rows: prefix-matching `merge` reds glab-neg-mrmerge; skipping bare
# words reds glab-neg-list-search-merge; dropping the flag-value skip reds glab-pos-global-repo.
case_begin "merge-detect: glab mr merge forms (table)" "hooks/lib/merge-detect.js"
while IFS='|' read -r name input want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  assert_eq "$name [$input]" "$want" "$(detect "$input")"
done <<'TABLE'
glab-pos-plain            | glab mr merge                                         | true|glab-mr-merge
glab-pos-squash-remove    | glab mr merge --squash --remove-source-branch         | true|glab-mr-merge
glab-pos-id-rebase-yes    | glab mr merge 12 --rebase --yes                       | true|glab-mr-merge
glab-pos-repo-flag        | glab mr merge 12 -R owner/repo                        | true|glab-mr-merge
glab-pos-wrapped-rtk      | rtk glab mr merge --squash                            | true|glab-mr-merge
glab-pos-wrapped-env      | env glab mr merge 12                                  | true|glab-mr-merge
glab-pos-chained-and      | echo ok && glab mr merge 12 --squash                  | true|glab-mr-merge
glab-pos-chained-semi     | git fetch origin; glab mr merge                       | true|glab-mr-merge
glab-neg-view             | glab mr view                                          | false|null
glab-neg-list             | glab mr list --merged                                 | false|null
glab-neg-mergeable        | glab mr mergeable 12                                  | false|null
glab-neg-merged-list      | glab mr merged-list                                   | false|null
glab-neg-create-title     | glab mr create --title merge                          | false|null
glab-neg-quoted           | echo "glab mr merge 1"                                | false|null
glab-neg-commented        | # glab mr merge 1                                     | false|null
gh-pos-baseline           | gh pr merge --squash --delete-branch                  | true|gh-pr-merge
gh-pos-baseline-rtk       | rtk gh pr merge --squash                              | true|gh-pr-merge
gh-pos-baseline-repo-flag | gh pr merge 123 -R owner/repo                         | true|gh-pr-merge
gh-pos-baseline-chained   | echo ok && gh pr merge --squash                       | true|gh-pr-merge
gh-neg-baseline-view      | gh pr view                                            | false|null
gh-neg-baseline-mergeable | gh pr mergeable                                       | false|null
gh-neg-baseline-quoted    | echo "gh pr merge 1"                                  | false|null
glab-pos-flag-between     | glab mr -R o/r merge 12                               | true|glab-mr-merge
glab-pos-flag-eq-between  | glab mr --repo=o/r merge                              | true|glab-mr-merge
glab-pos-global-repo      | glab -R owner/repo mr merge 12                        | true|glab-mr-merge
glab-pos-global-repo-long | glab --repo owner/repo mr merge                       | true|glab-mr-merge
glab-pos-global-repo-eq   | glab --repo=owner/repo mr merge 12                    | true|glab-mr-merge
gh-pos-global-repo        | gh -R o/r pr merge 1                                  | true|gh-pr-merge
gh-pos-flag-eq-between    | gh pr --repo=o/r merge 1                              | true|gh-pr-merge
glab-neg-flag-between-list| glab mr -R o/r list                                   | false|null
glab-neg-global-repo-list | glab -R owner/repo mr list                            | false|null
glab-neg-eq-then-list     | glab mr --repo=o/r list merge                         | false|null
glab-neg-list-search-merge| glab mr list --search merge                           | false|null
glab-neg-view-comments    | glab mr view 3 --comments                             | false|null
glab-neg-mrmerge          | glab mrmerge                                          | false|null
glab-neg-mergeable-bare   | glab mr mergeable                                     | false|null
gh-neg-view-number        | gh pr view 12                                         | false|null
gh-neg-list-search-merge  | gh pr list --search merge                             | false|null
TABLE
case_end

case_begin "merge gate: glab mr merge blocked while user_verification pending" "hooks/workflow-gate.js"
mk_state '{"sid":"mg-pend","version":4,"upto":"user_verification","steps":"user_verification=pending"}'
uv_events_before="$(ev_count mg-pend user_verification)"
out="$(gate_bash mg-pend "$RP_REPO_M" "glab mr merge --squash --remove-source-branch")"
check_contains "glab merge blocked with its kind" "$out" 'glab-mr-merge blocked'
check "glab merge decision is block" "$(hook_decision "$out")" "block"
out="$(gate_bash mg-pend "$RP_REPO_M" "rtk glab mr merge --squash")"
check_contains "wrapped glab merge blocked" "$out" 'glab-mr-merge blocked'
check "wrapped glab merge decision is block" "$(hook_decision "$out")" "block"
check "uv still pending after the blocks" "$(last_status mg-pend user_verification)" "pending"
check "no uv event written by a blocked merge" "$(ev_count mg-pend user_verification)" "$uv_events_before"
check "no reset_reason written by a blocked merge" "$(last_reset mg-pend user_verification)" "<none>"
out="$(gate_bash mg-pend "$RP_REPO_M" "gh pr merge --squash --delete-branch")"
check_contains "baseline: gh pr merge blocked" "$out" 'gh-pr-merge blocked'
check "baseline: gh pr merge decision is block" "$(hook_decision "$out")" "block"
case_end

case_begin "merge gate: global-flag glab mr merge blocked while pending, global-flag list allowed" "hooks/workflow-gate.js"
mk_state '{"sid":"mg-glob","version":4,"upto":"user_verification","steps":"user_verification=pending"}'
out="$(gate_bash mg-glob "$RP_REPO_M" "glab -R owner/repo mr merge 12")"
check_contains "global-flag glab merge blocked with its kind" "$out" 'glab-mr-merge blocked'
check "global-flag glab merge decision is block" "$(hook_decision "$out")" "block"
out="$(gate_bash mg-glob "$RP_REPO_M" "gh -R o/r pr merge 1")"
check "global-flag gh merge decision is block" "$(hook_decision "$out")" "block"
out="$(gate_bash mg-glob "$RP_REPO_M" "glab -R owner/repo mr list")"
check_not_contains "global-flag glab list not merge-gated" "$out" 'glab-mr-merge blocked'
check "global-flag glab list decision is approve" "$(hook_decision "$out")" "approve"
check "uv still pending after the global-flag block" "$(last_status mg-glob user_verification)" "pending"
case_end

# runcmds_json <sid> <cwd> <exit> <cmd...> — a runCommands payload (commands array), the shape
# hooks read per element through hooks/lib/tool-command-text.js commandListOf.
runcmds_json() {
  node -e 'const [sid, cwd, ex, ...cmds] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({ tool_name: "runCommands", session_id: sid,
      tool_input: { commands: cmds, cwd: cwd }, tool_response: { exit_code: Number(ex) } }))' "$@"
}

case_begin "merge gate: array form, harmless command before glab mr merge is still gated" "hooks/workflow-gate.js"
mk_state '{"sid":"mg-arr","version":4,"upto":"user_verification","steps":"user_verification=pending"}'
out="$(runcmds_json mg-arr "$RP_REPO_M" 0 "git status" "glab mr merge --squash" | run_with_timeout 60 node "$GATE_JS" 2>&1)"
check "array glab merge decision is block" "$(hook_decision "$out")" "block"
check_contains "array glab merge blocked with its kind" "$out" 'glab-mr-merge blocked'
out="$(runcmds_json mg-arr "$RP_REPO_M" 0 "git status" "gh pr merge --squash" | run_with_timeout 60 node "$GATE_JS" 2>&1)"
check "baseline: array gh merge decision is block" "$(hook_decision "$out")" "block"
check "uv still pending after the array blocks" "$(last_status mg-arr user_verification)" "pending"
case_end

case_begin "workflow-mark: array form, glab merge after a harmless command resets uv" "hooks/workflow-mark.js"
mk_state '{"sid":"mm-arr","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
runcmds_json mm-arr "$RP_REPO_M" 0 "git status" "glab mr merge --squash" | run_with_timeout 60 node "$MARK_JS" >/dev/null 2>&1
check "uv pending after array glab merge" "$(last_status mm-arr user_verification)" "pending"
check "reset_reason post-merge (array glab)" "$(last_reset mm-arr user_verification)" "post-merge"
mk_state '{"sid":"mm-arr-gh","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
runcmds_json mm-arr-gh "$RP_REPO_M" 0 "git status" "gh pr merge --squash" | run_with_timeout 60 node "$MARK_JS" >/dev/null 2>&1
check "baseline: uv pending after array gh merge" "$(last_status mm-arr-gh user_verification)" "pending"
check "baseline: reset_reason post-merge (array gh)" "$(last_reset mm-arr-gh user_verification)" "post-merge"
case_end

case_begin "merge gate: glab mr merge approved once user_verification complete" "hooks/workflow-gate.js"
mk_state '{"sid":"mg-ok","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
out="$(gate_bash mg-ok "$RP_REPO_M" "glab mr merge --squash --remove-source-branch")"
check "glab merge decision is approve" "$(hook_decision "$out")" "approve"
out="$(gate_bash mg-ok "$RP_REPO_M" "glab mr view")"
check_not_contains "glab mr view never gated" "$out" 'blocked'
check "glab mr view decision is approve" "$(hook_decision "$out")" "approve"
case_end

case_begin "workflow-mark: glab merge success resets uv with post-merge" "hooks/workflow-mark.js"
mk_state '{"sid":"mm-glab","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
mark_bash mm-glab "$RP_REPO_M" "glab mr merge --squash --remove-source-branch" 0 >/dev/null
check "uv pending after glab merge" "$(last_status mm-glab user_verification)" "pending"
check "reset_reason post-merge" "$(last_reset mm-glab user_verification)" "post-merge"
case_end

# The repeat is idempotent per 3-2b (an already boundary-reset uv gets no further uv events).
# Today's gh path appends a second pending + reset_reason pair on a repeat, so no gh row here.
case_begin "workflow-mark: the same successful glab merge event twice is idempotent" "hooks/workflow-mark.js"
mk_state '{"sid":"mm-twice","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
mark_bash mm-twice "$RP_REPO_M" "glab mr merge --squash --remove-source-branch" 0 >/dev/null
check "first event: uv pending" "$(last_status mm-twice user_verification)" "pending"
check "first event: reset_reason post-merge" "$(last_reset mm-twice user_verification)" "post-merge"
events_once="$(ev_query mm-twice 'e.length')"
uv_once="$(ev_count mm-twice user_verification)"
mark_bash mm-twice "$RP_REPO_M" "glab mr merge --squash --remove-source-branch" 0 >/dev/null
check "repeat: uv still pending" "$(last_status mm-twice user_verification)" "pending"
check "repeat: reset_reason still post-merge" "$(last_reset mm-twice user_verification)" "post-merge"
check "repeat: no new user_verification events" "$(ev_count mm-twice user_verification)" "$uv_once"
check "repeat: total event count unchanged" "$(ev_query mm-twice 'e.length')" "$events_once"
case_end

case_begin "workflow-mark: failed glab merge (exit 1) resets nothing" "hooks/workflow-mark.js"
mk_state '{"sid":"mm-fail","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
mark_bash mm-fail "$RP_REPO_M" "glab mr merge --squash" 1 >/dev/null
check "uv stays complete" "$(last_status mm-fail user_verification)" "complete"
case_end

case_begin "workflow-mark: protected push resets uv with post-push" "hooks/workflow-mark.js"
mk_state '{"sid":"mm-push","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
mark_bash mm-push "$RP_REPO_M" "git push origin main" 0 >/dev/null
check "uv pending after protected push" "$(last_status mm-push user_verification)" "pending"
check "reset_reason post-push" "$(last_reset mm-push user_verification)" "post-push"
case_end

case_begin "workflow-mark baseline: gh pr merge resets uv with post-merge" "hooks/workflow-mark.js"
mk_state '{"sid":"mm-gh","version":4,"upto":"cleanup","steps":"user_verification=complete"}'
mark_bash mm-gh "$RP_REPO_M" "gh pr merge --squash --delete-branch" 0 >/dev/null
check "uv pending after gh merge" "$(last_status mm-gh user_verification)" "pending"
check "reset_reason post-merge" "$(last_reset mm-gh user_verification)" "post-merge"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
