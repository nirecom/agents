# shellcheck shell=bash
# Tests: hooks/workflow-gate/review-docs-checker.js, bin/review-doc-gates, hooks/lib/staged-doc-changes.js
# Tags: TL2, docs, review-docs, staged, git, workflow-gate, scope:issue-specific, pwsh-not-required
#
# GROUP E: checkReviewDocs(step, stepState, {docsOnly, repoDir, sessionId}). It
# asks hasStagedDocChanges first (no staged .md → skip), then runs
# review-doc-gates --staged: pass → skip, fail → block with a reason. The
# recorded step status is NOT trusted: staged docs that violate always block.

# check_docs <repoDir> <stepStatus> — call checkReviewDocs and print
# "<action>|<hasReason>".
check_docs() {
  local repo_n; repo_n="$(nrm "$1")"
  E_REPO="$repo_n" E_STATUS="$2" run_node -e '
const { checkReviewDocs } = require(process.env.MOD_N);
const r = checkReviewDocs("review_docs", { status: process.env.E_STATUS },
  { docsOnly: true, repoDir: process.env.E_REPO, sessionId: "test-sid-2340-e" }) || {};
process.stdout.write(String(r.action) + "|" + (r.reason ? "reason" : "no-reason"));
' 2>&1
}

# check_docs_do <repoDir> <stepStatus> <docsOnly:true|false> — same as check_docs
# but docsOnly is a parameter, so the docsOnly=false (normal workflow) path is
# exercised too. Prints "<action>|<hasReason>".
check_docs_do() {
  local repo_n; repo_n="$(nrm "$1")"
  E_REPO="$repo_n" E_STATUS="$2" E_DOCSONLY="$3" run_node -e '
const { checkReviewDocs } = require(process.env.MOD_N);
const r = checkReviewDocs("review_docs", { status: process.env.E_STATUS },
  { docsOnly: process.env.E_DOCSONLY === "true", repoDir: process.env.E_REPO, sessionId: "test-sid-2340-e" }) || {};
process.stdout.write(String(r.action) + "|" + (r.reason ? "reason" : "no-reason"));
' 2>&1
}

# stage_bad_readme <repo> — README with an inverted heading order (a gate fail).
stage_bad_readme() {
  local repo="$1"
  {
    echo "# Project"
    echo "## Configuration"
    echo "cfg"
    echo "## Quickstart"
    echo "qs"
  } > "$repo/README.md"
  git -C "$repo" add README.md >/dev/null 2>&1
}

# stage_good_readme <repo> — canonical order, small (a gate pass).
stage_good_readme() {
  local repo="$1"
  {
    echo "# Project"
    echo "## What"
    echo "w"
    echo "## Quickstart"
    echo "qs"
    echo "## Usage"
    echo "u"
    echo "## Configuration"
    echo "cfg"
  } > "$repo/README.md"
  git -C "$repo" add README.md >/dev/null 2>&1
}

run_group_e() {
  require_module "E" "hooks/workflow-gate/review-docs-checker.js" || return 0
  export MOD_N="$AGENTS_DIR_N/hooks/workflow-gate/review-docs-checker.js"
  local repo out

  # E1: no staged docs → skip regardless of step state.
  repo="$(new_doc_repo)"
  out="$(check_docs "$repo" pending)"
  assert_eq "E1: no staged docs → action=skip" "skip|no-reason" "$out"

  # E2: staged docs that pass the gates → skip.
  repo="$(new_doc_repo)"
  stage_good_readme "$repo"
  out="$(check_docs "$repo" pending)"
  assert_eq "E2: staged docs + gates pass → action=skip" "skip|no-reason" "$out"

  # E3: staged docs that violate the gates → block with a reason.
  repo="$(new_doc_repo)"
  stage_bad_readme "$repo"
  out="$(check_docs "$repo" pending)"
  assert_eq "E3: staged docs + gates fail → action=block with reason" "block|reason" "$out"

  # E4: review_docs recorded complete, but staged docs violate → still blocks.
  # The checker re-runs the gate rather than trusting the recorded status.
  repo="$(new_doc_repo)"
  stage_bad_readme "$repo"
  out="$(check_docs "$repo" complete)"
  assert_eq "E4: complete status but violating staged docs → still block" "block|reason" "$out"

  # --- E-NEW: docsOnly=false branch (#2340 gap C5). E1-E4 drive docsOnly=true
  # (the workflow-gate.js short-circuit). review_docs is the exception the
  # short-circuit must NOT skip, so the checker must block on violating staged
  # docs in the normal (docsOnly=false) workflow path too. ---

  # E-NEW-1: docsOnly=false, review_docs pending, violating staged docs →
  # still checks and blocks with a reason.
  repo="$(new_doc_repo)"
  stage_bad_readme "$repo"
  out="$(check_docs_do "$repo" pending false)"
  assert_eq "E-NEW-1: docsOnly=false + violating staged docs → still block" "block|reason" "$out"

  # E-NEW-2: docsOnly=false, review_docs pending, PASSING staged docs → skip.
  # Complements E-NEW-1: the docsOnly=false path must not over-block clean docs.
  repo="$(new_doc_repo)"
  stage_good_readme "$repo"
  out="$(check_docs_do "$repo" pending false)"
  assert_eq "E-NEW-2: docsOnly=false + passing staged docs → skip" "skip|no-reason" "$out"
}
