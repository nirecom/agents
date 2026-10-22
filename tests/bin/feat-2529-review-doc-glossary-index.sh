#!/usr/bin/env bash
# tests/bin/feat-2529-review-doc-glossary-index.sh
# Tests: bin/review-doc-glossary, bin/lib/glossary-format.js
# Tags: TL2, docs, glossary, review-docs, staged, git, gate, classifier, scope:issue-specific, pwsh-not-required
# #2529 glossary gate, part 3 (split from feat-2529-review-doc-glossary.sh on the time budget):
# the docs/glossary.md index page holds no entries (rules/docs/glossary.md).
# TL3 gap (what this test does NOT catch):
# - the gate firing from the real pre-commit / review_docs step on a live commit.
# Closest-to-action mitigation: review-doc-gates aggregate is covered by tests/bin/docs-2340-feat-update-docs-readme-md.sh C6.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(make_tmp)"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT

source "$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2529-review-doc-glossary/common.sh"

# A staged `### ` heading outside fenced code in the index BLOCKs (an unclosed fence would hide
# one, so it BLOCKs too); a heading inside a fence and plain links / prose pass.
# Rows: label | index content (printf format) | want rc | want output fragment
INDEX_ROWS=(
  "index-entry-blocks|# Glossary\n\nSee [user](glossary/user.md).\n\n### stray term\n- **Definition**: x.\n|1|move \"### stray term\" to its category file"
  "index-fenced-heading-passes|# Glossary\n\n\`\`\`md\n### example term\n\`\`\`\n\nSee [user](glossary/user.md).\n|0|SKIPPED"
  "index-links-and-prose-pass|# Glossary\n\nThe glossary is split by category.\n\n- [user](glossary/user.md)\n- [internal](glossary/internal.md)\n|0|SKIPPED"
  "index-unclosed-fence-blocks|# Glossary\n\n\`\`\`md\n### hidden term\n|1|unclosed code fence"
)
case_begin "glossary-index-holds-no-entries" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" alpha beta
commit_all "$REPO"
for row in "${INDEX_ROWS[@]}"; do
  IFS='|' read -r label body want_rc want_out <<<"$row"
  # shellcheck disable=SC2059 # the row body is the printf format by design
  printf "$body" > "$REPO/docs/glossary.md"
  stage "$REPO" docs/glossary.md
  run_gate "$REPO" --staged
  expect_rc "$label" "$want_rc"
  expect_out "$label output" "$want_out"
done
case_end

case_begin "glossary-index-entry-all-mode-is-advisory" "bin/review-doc-glossary"
printf '# Glossary\n\n### stray term\n' > "$REPO/docs/glossary.md"
run_gate "$REPO" --all
expect_rc "index entry in --all mode" 0
expect_out "index entry reported in --all mode" "the index holds no entries"
case_end

case_begin "glossary-index-deleted-passes" "bin/review-doc-glossary"
commit_all "$REPO"
git -C "$REPO" rm -q --cached docs/glossary.md
run_gate "$REPO" --staged
expect_rc "staged deletion of an index that held an entry" 0
expect_out "deletion skip reported" "SKIPPED"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
