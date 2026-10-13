#!/usr/bin/env bash
# feature-2527-merge-detect-graphql.sh — #2527 4-1: a GraphQL merge mutation is a merge to protected.
# Tests: hooks/lib/merge-detect.js, hooks/lib/merge-detect/graphql.js
# Tags: scope:issue-specific, workflow, merge-gate, TL1
# TL1: table-driven unit calls to isMergeToProtectedCommand / checkGraphqlMerge (no hook spawn).
# Contract (plan 4-1, judgment B): `gh|glab api graphql` + a merge mutation name as a whole word,
# in any of -f / -F / --raw-field / --field, reuses the existing kind (gh-pr-merge for the GitHub
# mutations mergePullRequest / enablePullRequestAutoMerge, glab-mr-merge for GitLab
# mergeRequestAccept). Out of scope by design: --input, @file, stdin, variables, curl.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/feature-2527-auto-merge-pr-fix/_lib.sh"

# TL3 gap (not caught here): a real `gh api graphql` mutation reaching GitHub and merging.
# Closest-to-action mitigation: forge-side branch protection (docs/ops.md recommends it).
# category: hook-registration.
AMP_TMP="$(make_tmp)"
readonly AMP_TMP
trap amp_teardown EXIT
harness_isolate "$AMP_TMP"
cd "$AMP_TMP" || exit 1

# detect <command> — "<hit>|<kind>" from isMergeToProtectedCommand.
detect() {
  amp_node 'const m = req("hooks/lib/merge-detect.js");
const r = m.isMergeToProtectedCommand(process.argv[1]);
console.log(r.hit + "|" + r.kind);' "$1"
}
# detect_graphql <segment> — "<hit>|<kind>" from checkGraphqlMerge alone.
detect_graphql() {
  amp_node 'const g = req("hooks/lib/merge-detect/graphql.js");
if (typeof g.checkGraphqlMerge !== "function") { console.log("NOT-EXPORTED"); process.exit(0); }
const r = g.checkGraphqlMerge(process.argv[1]) || {};
console.log(Boolean(r.hit) + "|" + (r.kind || null));' "$1"
}

# run_table <fn> — reads "name | input | want" rows from stdin; blank and # rows are skipped.
run_table() {
  local fn="$1" name input want
  while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    check "$name [$input]" "$("$fn" "$input")" "$want"
  done
}

# Mutation Probe: the near-miss rows kill a prefix/substring match (neg-disable-automerge,
# neg-mutation-suffix), a missing endpoint check (neg-rest-endpoint-body), and quote-blind
# scanning (neg-echo-quoted); the flag rows kill a matcher that reads only one flag spelling.
case_begin "merge-detect: GraphQL merge mutations hit with the existing kinds (table)" "hooks/lib/merge-detect.js"
run_table detect <<'TABLE'
pos-gh-f            | gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'              | true|gh-pr-merge
pos-gh-F-inline     | gh api graphql -F query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'              | true|gh-pr-merge
pos-gh-raw-field    | gh api graphql --raw-field query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'     | true|gh-pr-merge
pos-gh-field        | gh api graphql --field query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'         | true|gh-pr-merge
pos-gh-spaced       | gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: "PR_1"}) { clientMutationId } }'      | true|gh-pr-merge
pos-gh-auto-merge   | gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:"PR_1"}){clientMutationId}}'    | true|gh-pr-merge
pos-gh-var-after    | gh api graphql -f query='mutation($id:ID!){mergePullRequest(input:{pullRequestId:$id}){clientMutationId}}' -f id=PR_1 | true|gh-pr-merge
pos-glab-accept     | glab api graphql -f query='mutation{mergeRequestAccept(input:{projectPath:"o/r",iid:"1"}){errors}}'              | true|glab-mr-merge
pos-wrapped-rtk     | rtk gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'          | true|gh-pr-merge
pos-wrapped-env     | env GH_HOST=github.com gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}' | true|gh-pr-merge
pos-wrapped-bash-c  | bash -c "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'"  | true|gh-pr-merge
pos-chained-and     | echo ok && gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'   | true|gh-pr-merge
pos-chained-semi    | git fetch origin; glab api graphql -f query='mutation{mergeRequestAccept(input:{projectPath:"o/r",iid:"1"}){errors}}' | true|glab-mr-merge
neg-read-query      | gh api graphql -f query='query{repository(owner:"o",name:"r"){pullRequest(number:1){mergeable}}}'               | false|null
neg-input-file      | gh api graphql --input merge-body.json                                                                          | false|null
neg-at-file         | gh api graphql -F query=@merge-pull-request.graphql                                                             | false|null
neg-no-mutation     | gh api graphql -f query='mutation{addComment(input:{subjectId:"X",body:"please merge"}){clientMutationId}}'      | false|null
neg-disable-automerge | gh api graphql -f query='mutation{disablePullRequestAutoMerge(input:{pullRequestId:"PR_1"}){clientMutationId}}' | false|null
neg-mutation-suffix | gh api graphql -f query='mutation{mergePullRequestX(input:{pullRequestId:"PR_1"}){clientMutationId}}'             | false|null
neg-glab-suffix     | glab api graphql -f query='mutation{mergeRequestAcceptance(input:{iid:"1"}){errors}}'                            | false|null
neg-rest-endpoint-body | gh api repos/o/r/issues -f title=mergePullRequest                                                            | false|null
neg-echo-quoted     | echo "gh api graphql -f query=mutation{mergePullRequest(input:{pullRequestId:1})}"                              | false|null
neg-not-api         | gh pr view 12 --json title                                                                                      | false|null
TABLE
case_end

# Baselines: the existing kinds keep their answers once graphql.js is wired in.
case_begin "merge-detect: existing merge forms keep their kinds (baseline table)" "hooks/lib/merge-detect.js"
run_table detect <<'TABLE'
base-gh-pr-merge    | gh pr merge --squash --delete-branch        | true|gh-pr-merge
base-glab-mr-merge  | glab mr merge --squash                      | true|glab-mr-merge
base-rest-put       | gh api -X PUT repos/o/r/pulls/1/merge       | true|gh-pr-merge
base-push-main      | git push origin main                        | true|git-push-protected
base-push-feature   | git push origin feature/2527-amp            | false|null
base-gh-api-get     | gh api repos/o/r/pulls/1                    | false|null
TABLE
case_end

case_begin "merge-detect/graphql: checkGraphqlMerge is exported and classifies alone (table)" "hooks/lib/merge-detect/graphql.js"
run_table detect_graphql <<'TABLE'
unit-gh-merge       | gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:"PR_1"}){clientMutationId}}'  | true|gh-pr-merge
unit-gh-auto        | gh api graphql --field query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:"P"}){clientMutationId}}' | true|gh-pr-merge
unit-glab-accept    | glab api graphql --raw-field query='mutation{mergeRequestAccept(input:{projectPath:"o/r",iid:"1"}){errors}}' | true|glab-mr-merge
unit-read-query     | gh api graphql -f query='query{viewer{login}}'                                                        | false|null
unit-non-graphql    | gh api repos/o/r/pulls -f title=mergePullRequest                                                      | false|null
TABLE
case_end

case_begin "merge-detect/graphql: merge-detect.js requires the graphql module (static)" "hooks/lib/merge-detect.js"
src="$(cat "$AMP_ROOT_M/hooks/lib/merge-detect.js" 2>/dev/null)"
check_contains "merge-detect.js requires ./merge-detect/graphql" "$src" "merge-detect/graphql"
check "graphql.js exists" "$([ -f "$AMP_ROOT_M/hooks/lib/merge-detect/graphql.js" ] && echo yes || echo no)" "yes"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
