#!/usr/bin/env bash
# tests/bin/feat-2529-review-doc-glossary.sh
# Tests: bin/review-doc-glossary, bin/lib/glossary-format.js
# Tags: TL2, docs, glossary, review-docs, staged, git, gate, classifier, scope:issue-specific, pwsh-not-required
# #2529 glossary gate, part 1: entry shape, order, cross-file duplicates, skip selection.
# Range sets / index selection / modes: feat-2529-review-doc-glossary-ranges.sh; the docs/glossary.md
# index page holding no entries: feat-2529-review-doc-glossary-index.sh. Fixture repos only.
# TL3 gap (what this test does NOT catch):
# - the gate firing from the real pre-commit / review_docs step on a live commit.
# Closest-to-action mitigation: review-doc-gates aggregate is covered by tests/bin/docs-2340-feat-update-docs-readme-md.sh C6 (the 500/501-line size boundary on a glossary is C7 there).
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(make_tmp)"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT

# Helpers shared with the range-split part (feat-2529-review-doc-glossary-ranges.sh).
source "$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2529-review-doc-glossary/common.sh"

case_begin "valid-user-and-internal-pass" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" alpha beta
gloss "$REPO/docs/glossary/internal.md" delta gamma
stage_as_prose_edit "$REPO" docs/glossary/user.md docs/glossary/internal.md
run_gate "$REPO" --staged
expect_rc "valid two files staged" 0
expect_out "header printed" "Doc-glossary Review"
case_end

case_begin "order-violation-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user.md" beta alpha
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "out-of-order entries" 1
expect_out "order violation reported" "BLOCK"
case_end

case_begin "case-insensitive-order-passes" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user.md" alpha Beta charlie
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "mixed-case terms in case-insensitive order" 0
case_end

case_begin "h2-heading-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '## Workflow\n\n' >> "$REPO/docs/glossary/user.md"
entry alpha >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "## section heading present" 1
expect_out "h2 violation reported" "BLOCK"
case_end

case_begin "definition-two-lines-passes" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
cat >> "$REPO/docs/glossary/user.md" <<'EOF'
### alpha
- **Definition**: line one of the definition
  line two of the definition
- **Related**: [owner](architecture/owner.md)
EOF
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "definition with one continuation line" 0
case_end

case_begin "definition-three-lines-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
cat >> "$REPO/docs/glossary/user.md" <<'EOF'
### alpha
- **Definition**: line one of the definition
  line two of the definition
  line three of the definition
- **Related**: [owner](architecture/owner.md)
EOF
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "definition spanning three lines" 1
expect_out "definition length reported" "BLOCK"
case_end

case_begin "missing-definition-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "entry without Definition" 1
case_end

case_begin "empty-definition-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Definition**:\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Definition with no text" 1
expect_out "empty definition reported" "BLOCK"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Definition**:   \n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Definition with only trailing whitespace" 1
case_end

case_begin "related-zero-links-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Definition**: a term.\n- **Related**: see the owner doc\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Related with no link" 1
case_end

case_begin "related-two-links-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Definition**: a term.\n- **Related**: [a](a.md), [b](b.md)\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Related with two links" 1
case_end

case_begin "related-todo-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Definition**: a term.\n- **Related**: TODO\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Related left as TODO" 1
case_end

case_begin "full-name-bullet-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### IR\n- **Full name**: intermediate representation\n- **Definition**: a term.\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Full name bullet present" 1
case_end

case_begin "level-bullet-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### alpha\n- **Level**: 2\n- **Definition**: a term.\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Level bullet present" 1
case_end

case_begin "cross-file-duplicate-blocks" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" alpha beta
gloss "$REPO/docs/glossary/internal.md" alpha gamma
stage "$REPO" docs/glossary/user.md docs/glossary/internal.md
run_gate "$REPO" --staged
expect_rc "same term in user and internal" 1
expect_out "duplicate term named" "alpha"
case_end

case_begin "nothing-staged-skips" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" beta alpha
commit_all "$REPO"
printf 'other\n' > "$REPO/other.txt"
stage "$REPO" other.txt
run_gate "$REPO" --staged
expect_rc "no glossary file staged (committed one is invalid)" 0
expect_out "skip reported" "SKIPPED"
case_end

case_begin "glossary-index-page-only-skips" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" beta alpha
commit_all "$REPO"
printf '# Glossary\n\n## User terms\n\nSee [user](glossary/user.md).\n' > "$REPO/docs/glossary.md"
stage "$REPO" docs/glossary.md
run_gate "$REPO" --staged
expect_rc "only docs/glossary.md staged" 0
expect_out "skip reported" "SKIPPED"
case_end

# A docs/glossary-*.md name outside docs/glossary/ is no longer a gate target at all
# (#2529 restructure); the unknown-name block inside docs/glossary/ is unparseable-name-blocks.
case_begin "foreign-glossary-name-ignored" "bin/review-doc-glossary"
new_repo
printf '# Glossary\n\n## Not an entry file\n\n### zeta\n### alpha\n' > "$REPO/docs/glossary-foo.md"
stage "$REPO" docs/glossary-foo.md
run_gate "$REPO" --staged
expect_rc "only docs/glossary-foo.md staged" 0
expect_out "skip reported" "SKIPPED"
gloss "$REPO/docs/glossary/user.md" alpha beta
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "glossary-foo.md beside a valid user file is not checked" 0
case_end

# #2763 S2: the optional Identifier / Homographs bullets. The BLOCK cases are staged like the pass
# case and must block on the field value, not as a disallowed bullet.
expect_no_disallowed() {
  if [[ "$GATE_OUT" != *"disallowed bullet"* ]]; then pass "$1 (not a disallowed bullet)"
  else fail "$1" "blocked as a disallowed bullet: ${GATE_OUT:0:600}"; fi
}

case_begin "identifier-bullet-passes" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### allow-deny hook\n- **Definition**: a fixture term.\n- **Identifier**: `allow-deny-hook`, `allow_deny_hook`\n- **Related**: [owner](architecture/owner.md)\n\n' >> "$REPO/docs/glossary/user.md"
printf '### statusline\n- **Definition**: a fixture term.\n- **Homographs**: `statuses`\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "valid Identifier and Homographs bullets" 0
case_end

case_begin "identifier-key-mismatch-blocks" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### allow-deny hook\n- **Definition**: a fixture term.\n- **Identifier**: `allow-deny-hooks`\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Identifier whose identKey differs from the term" 1
expect_no_disallowed "Identifier identKey mismatch"
case_end

case_begin "homographs-separator-plural-blocks" "bin/review-doc-glossary"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '### statusline\n- **Definition**: a fixture term.\n- **Homographs**: `status-lines`\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary/user.md"
stage_as_prose_edit "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "Homographs holding a separator variant plural of the term" 1
expect_no_disallowed "Homographs separator variant plural"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
