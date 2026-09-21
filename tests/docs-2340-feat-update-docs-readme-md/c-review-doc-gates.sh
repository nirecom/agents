# shellcheck shell=bash
# Tests: bin/review-doc-gates, bin/review-doc-size, bin/review-doc-heading-order
# Tags: TL2, docs, review-docs, staged, git, aggregate, scope:issue-specific, pwsh-not-required
#
# GROUP C: the aggregate gate. review-doc-gates delegates to review-doc-size and
# review-doc-heading-order and OR-folds their exit codes: exit 1 if EITHER
# sub-tool blocks, exit 0 only when both pass. --all stays advisory (always 0).

# stage_readme_c <repo> <n-lines> <heading-lines...> — README.md padded to N
# lines with the given ordered H2 sections, staged. N controls the size gate,
# the heading order controls the heading gate.
stage_readme_c() {
  local repo="$1" n="$2"; shift 2
  local f="$repo/README.md" h i emitted=0
  {
    echo "# Project"
    for h in "$@"; do
      echo "## $h"
      echo "body of $h"
      emitted=$((emitted + 2))
    done
    for ((i = emitted + 2; i <= n; i++)); do echo "filler $i"; done
  } > "$f"
  git -C "$repo" add README.md >/dev/null 2>&1
}

run_group_c() {
  require_bin "C" "bin/review-doc-gates" || return 0
  local repo

  # C1: size violation only (>500 lines, order canonical) → aggregate blocks.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 550 "What" "Quickstart" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C1: size violation only → --staged exits 1" "1" "$TOOL_RC"

  # C2: heading-order violation only (small file, inverted order) → aggregate blocks.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 40 "What" "Configuration" "Quickstart" "Usage"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C2: heading-order violation only → --staged exits 1" "1" "$TOOL_RC"

  # C3: both violations at once → aggregate still non-zero (no double-count bug).
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 550 "Configuration" "Quickstart"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C3: both violations → --staged exits 1" "1" "$TOOL_RC"

  # C4: neither violated → clean pass.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 250 "What" "Quickstart" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C4: no violations → --staged exits 0" "0" "$TOOL_RC"

  # C5: --all is advisory even when both sub-gates would block.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 550 "Configuration" "Quickstart"
  run_tool "$repo" "bin/review-doc-gates" --all
  assert_eq "C5: --all exits 0 even with violations (advisory)" "0" "$TOOL_RC"
}
