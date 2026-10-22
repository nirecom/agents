#!/usr/bin/env bash
# tests/bin/feat-2529-review-doc-glossary-ranges.sh
# Tests: bin/review-doc-glossary, bin/lib/glossary-format.js
# Tags: TL2, docs, glossary, review-docs, staged, git, gate, classifier, scope:issue-specific, pwsh-not-required
# #2529 glossary gate, part 2 (split from feat-2529-review-doc-glossary.sh on the time budget):
# range-split file sets, staged-vs-index-vs-worktree selection, deletions, modes, H1 rules.
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

case_begin "range-split-valid-passes" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" alpha mike
gloss "$REPO/docs/glossary/user-n-z.md" november zulu
stage_as_prose_edit "$REPO" docs/glossary/user-a-m.md docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "a-m + n-z with in-range terms" 0
case_end

case_begin "out-of-range-term-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" alpha zeta
gloss "$REPO/docs/glossary/user-n-z.md" november
stage "$REPO" docs/glossary/user-a-m.md docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "zeta in the a-m file" 1
expect_out "out-of-range term named" "zeta"
case_end

case_begin "non-alpha-leading-terms-in-a-range-pass" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" 2fa _foo alpha
gloss "$REPO/docs/glossary/user-n-z.md" nu
stage_as_prose_edit "$REPO" docs/glossary/user-a-m.md docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "2fa and _foo in the range starting at a" 0
case_end

case_begin "non-alpha-leading-term-outside-a-range-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" alpha
gloss "$REPO/docs/glossary/user-n-z.md" _foo nu
stage "$REPO" docs/glossary/user-a-m.md docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "_foo in the n-z file" 1
expect_out "out-of-range term named" "_foo"
case_end

case_begin "range-overlap-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" alpha
gloss "$REPO/docs/glossary/user-m-z.md" zulu
stage "$REPO" docs/glossary/user-a-m.md docs/glossary/user-m-z.md
run_gate "$REPO" --staged
expect_rc "a-m and m-z overlap on m" 1
case_end

case_begin "range-gap-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-l.md" alpha
gloss "$REPO/docs/glossary/user-n-z.md" zulu
stage "$REPO" docs/glossary/user-a-l.md docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "a-l and n-z leave m uncovered" 1
case_end

case_begin "unsplit-and-ranged-coexist-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user.md" alpha
gloss "$REPO/docs/glossary/user-a-m.md" beta
gloss "$REPO/docs/glossary/user-n-z.md" zulu
stage "$REPO" docs/glossary/user.md docs/glossary/user-a-m.md docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "glossary/user.md beside a full ranged set" 1
case_end

case_begin "unparseable-name-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-foo.md" alpha
stage "$REPO" docs/glossary/user-foo.md
run_gate "$REPO" --staged
expect_rc "glossary/user-foo.md" 1
expect_out "unparseable file named" "user-foo.md"
case_end

case_begin "reversed-range-name-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" alpha
gloss "$REPO/docs/glossary/user-z-n.md" zulu
stage "$REPO" docs/glossary/user-a-m.md docs/glossary/user-z-n.md
run_gate "$REPO" --staged
expect_rc "from > to range name" 1
case_end

case_begin "partial-stage-checks-other-ranged-file-from-index" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" beta
gloss "$REPO/docs/glossary/user-n-z.md" aardvark nu
commit_all "$REPO"
gloss "$REPO/docs/glossary/user-a-m.md" beta charlie
stage "$REPO" docs/glossary/user-a-m.md
run_gate "$REPO" --staged
expect_rc "unstaged n-z in the index still violates" 1
expect_out "violation in the unstaged file named" "aardvark"
case_end

# The staged a-m change is prose-only so the pass verdict depends on the file selection alone,
# not on a term operation the glossary provenance check would block (#2529).
case_begin "partial-stage-reads-index-not-worktree-of-other-file" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" beta
gloss "$REPO/docs/glossary/user-n-z.md" nu
commit_all "$REPO"
gloss "$REPO/docs/glossary/user-n-z.md" aardvark nu
prose_edit "$REPO/docs/glossary/user-a-m.md"
stage "$REPO" docs/glossary/user-a-m.md
run_gate "$REPO" --staged
expect_rc "unstaged worktree breakage in n-z is not read" 0
case_end

case_begin "index-wins-over-worktree" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" alpha beta
stage_as_prose_edit "$REPO" docs/glossary/user.md
gloss "$REPO/docs/glossary/user.md" beta alpha
run_gate "$REPO" --staged
expect_rc "valid index, broken worktree" 0
new_repo
gloss "$REPO/docs/glossary/user.md" beta alpha
stage "$REPO" docs/glossary/user.md
gloss "$REPO/docs/glossary/user.md" alpha beta
run_gate "$REPO" --staged
expect_rc "broken index, fixed worktree" 1
case_end

case_begin "staged-deletion-leaving-range-gap-blocks" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md" alpha mike
gloss "$REPO/docs/glossary/user-n-z.md" november zulu
commit_all "$REPO"
git -C "$REPO" rm -q docs/glossary/user-n-z.md
run_gate "$REPO" --staged
expect_rc "deleting n-z leaves a-m alone with n-z uncovered" 1
case_end

# The deleted files hold no entries, so the deletion carries zero term operations and the
# pass verdict stays about the empty file set, not about provenance (#2529).
case_begin "staged-deletion-of-every-glossary-file-passes" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user-a-m.md"
gloss "$REPO/docs/glossary/user-n-z.md"
gloss "$REPO/docs/glossary/internal.md"
commit_all "$REPO"
git -C "$REPO" rm -q docs/glossary/user-a-m.md docs/glossary/user-n-z.md docs/glossary/internal.md
run_gate "$REPO" --staged
expect_rc "no glossary file left in the index" 0
if [[ "$GATE_RC" != 127 && "$GATE_OUT" != *BLOCK* ]]; then pass "no BLOCK finding when the index holds no glossary file"
else fail "no BLOCK finding when the index holds no glossary file" "output: ${GATE_OUT:0:600}"; fi
case_end

case_begin "all-mode-is-advisory" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" beta alpha
run_gate "$REPO" --all
expect_rc "--all with an order violation" 0
expect_out "--all still reports the finding" "BLOCK"
case_end

case_begin "mode-selection-skips" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary/user.md" beta alpha
stage "$REPO" docs/glossary/user.md
run_gate "$REPO"
expect_rc "no mode selected" 0
expect_out "no-mode skip reported" "SKIPPED"
run_gate "$REPO" --staged --all
expect_rc "--staged and --all together" 0
expect_out "mutual-exclusion skip reported" "SKIPPED"
case_end

case_begin "deep-heading-before-first-entry-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '#### Stray deep heading\n\n' >> "$REPO/docs/glossary/user.md"
entry alpha >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "#### heading before the first entry" 1
expect_out "deep heading reported" "BLOCK"
case_end

case_begin "missing-h1-blocks" "bin/lib/glossary-format.js"
new_repo
printf 'Intro without a title.\n\n' > "$REPO/docs/glossary/user.md"
entry alpha >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "file without an H1" 1
expect_out "missing H1 reported" "H1"
case_end

case_begin "second-h1-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary/user.md"
printf '# Second title\n\n' >> "$REPO/docs/glossary/user.md"
entry alpha >> "$REPO/docs/glossary/user.md"
stage "$REPO" docs/glossary/user.md
run_gate "$REPO" --staged
expect_rc "file with two H1 lines" 1
expect_out "second H1 reported" "only one"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
