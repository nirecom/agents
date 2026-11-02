#!/usr/bin/env bash
# tests/bin/feat-2529-review-doc-glossary-index.sh
# Tests: bin/review-doc-glossary, bin/lib/glossary-format.js
# Tags: TL2, docs, glossary, review-docs, staged, git, gate, classifier, scope:issue-specific, pwsh-not-required, glossary-fields
# #2529 glossary gate, part 3 (split from feat-2529-review-doc-glossary.sh on the time budget):
# the docs/glossary.md index page holds no entries (rules/docs/glossary.md); #2763 Identifier / Short forms bullets.
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

# #2763: the optional Identifier / Short forms bullets through the gate. The BLOCK cases are
# staged like the pass cases and must block on the field value, not as a disallowed bullet.
case_begin "identifier-bullet-passes" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### allow-deny hook\n- **Definition**: a fixture term.\n- **Identifier**: `allow-deny-hook`, `allow_deny_hook`\n- **Related**: [owner](architecture/owner.md)\n\n' >> "$REPO/docs/glossary/user.md"
sf_entry "status line" status >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "valid Identifier and Short forms bullets" 0
case_end

case_begin "identifier-key-mismatch-blocks" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### allow-deny hook\n- **Definition**: a fixture term.\n- **Identifier**: `allow-deny-hooks`\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Identifier whose identKey differs from the term" 1
expect_out "mismatch names the entry and field" "'allow-deny hook' Identifier"
expect_out "mismatch names the spelling" "allow-deny-hooks"
expect_no_disallowed "Identifier identKey mismatch"
case_end

case_begin "short-forms-not-subsequence-blocks" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
sf_entry "status line" lines >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Short forms holding a word that is not in the headword" 1
expect_out "subsequence violation names the entry and field" "'status line' Short forms"
expect_out "subsequence violation names the spelling" "lines"
expect_no_disallowed "Short forms not a word subsequence"
case_end

# A short form of a user entry equal to an internal headword: each file is valid on its own, so
# only the cross-file overlap check can block it.
case_begin "short-forms-cross-file-overlap-blocks" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
sf_entry "alpha gate" gate >> "$REPO/docs/glossary/user.md"
gloss "$REPO/docs/glossary/internal.md" gate
stage_as_prose_edit "$REPO" docs/glossary/user.md docs/glossary/internal.md
run_gate "$REPO" --staged
expect_rc "Short forms equal to a headword of the other file" 1
expect_out "overlap names the entry" "alpha gate"
expect_out "overlap names the other file's headword" "gate"
expect_no_disallowed "Short forms cross-file overlap"
case_end

# The six Short forms the issue plans for the real user glossary pass together.
case_begin "short-forms-six-planned-bullets-pass" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
sf_entry "detail plan" detail >> "$REPO/docs/glossary/user.md"
sf_entry "intent plan" intent >> "$REPO/docs/glossary/user.md"
sf_entry "meta issue" meta >> "$REPO/docs/glossary/user.md"
sf_entry "outline plan" outline >> "$REPO/docs/glossary/user.md"
sf_entry "workflow sentinel" sentinel >> "$REPO/docs/glossary/user.md"
sf_entry "workflow step" step >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "six planned Short forms bullets" 0
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
