#!/usr/bin/env bash
# tests/bin/feat-2529-review-doc-glossary.sh
# Tests: bin/review-doc-glossary, bin/lib/glossary-format.js
# Tags: TL2, docs, glossary, review-docs, staged, git, gate, classifier, scope:issue-specific, pwsh-not-required
# #2529 glossary gate: entry shape, order, cross-file duplicates, range-split file sets,
# staged-vs-index-vs-worktree selection. Fixture repos only; the gate never sees the real repo.
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

GATE="$SCRIPT_CHECKOUT_ROOT/bin/review-doc-glossary"
REPO=""
REPO_SEQ=0

# new_repo — fresh fixture git repo with one baseline commit; sets REPO.
new_repo() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="$T/repo-$REPO_SEQ"
  mkdir -p "$REPO/docs"
  harness_git_init "$REPO"
  git -C "$REPO" config core.autocrlf false
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "test"
  printf 'baseline\n' > "$REPO/.seed"
  git -C "$REPO" add .seed
  git -C "$REPO" commit -q -m baseline
}

# gloss_head <file> — H1 + one-line intro, no entries.
gloss_head() {
  mkdir -p "$(dirname "$1")"
  printf '# Glossary\n\nFixture glossary for the #2529 gate tests.\n\n' > "$1"
}

# entry <term> — one valid entry block.
entry() {
  printf '### %s\n- **Definition**: %s is a fixture term.\n- **Related**: [owner](architecture/owner.md)\n\n' "$1" "$1"
}

# gloss <file> <term>... — a valid glossary file holding the terms in the given order.
gloss() {
  local f="$1" t
  shift
  gloss_head "$f"
  for t in "$@"; do entry "$t" >> "$f"; done
}

stage() {
  local r="$1"
  shift
  git -C "$r" add -- "$@"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m fixture
}

# run_gate <repo> <args...> — sets GATE_OUT / GATE_RC; a missing gate fails loudly (RED).
run_gate() {
  local r="$1"
  shift
  if [[ ! -f "$GATE" ]]; then
    GATE_OUT="TOOL NOT FOUND: bin/review-doc-glossary (not yet implemented, #2529)"
    GATE_RC=127
    return 0
  fi
  GATE_RC=0
  GATE_OUT="$(cd "$r" && run_with_timeout 120 bash "$GATE" "$@" 2>&1)" || GATE_RC=$?
}

expect_rc() {
  if [[ "$GATE_RC" == "$2" ]]; then pass "$1 (rc=$2)"
  else fail "$1" "want rc=$2 got rc=$GATE_RC; output: ${GATE_OUT:0:600}"; fi
}

expect_out() {
  if [[ "$GATE_OUT" == *"$2"* ]]; then pass "$1 (output has [$2])"
  else fail "$1" "expected [$2] in output: ${GATE_OUT:0:600}"; fi
}

case_begin "valid-user-and-internal-pass" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" alpha beta
gloss "$REPO/docs/glossary-internal.md" delta gamma
stage "$REPO" docs/glossary-user.md docs/glossary-internal.md
run_gate "$REPO" --staged
expect_rc "valid two files staged" 0
expect_out "header printed" "Doc-glossary Review"
case_end

case_begin "order-violation-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user.md" beta alpha
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "out-of-order entries" 1
expect_out "order violation reported" "BLOCK"
case_end

case_begin "case-insensitive-order-passes" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user.md" alpha Beta charlie
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "mixed-case terms in case-insensitive order" 0
case_end

case_begin "h2-heading-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '## Workflow\n\n' >> "$REPO/docs/glossary-user.md"
entry alpha >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "## section heading present" 1
expect_out "h2 violation reported" "BLOCK"
case_end

case_begin "definition-two-lines-passes" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
cat >> "$REPO/docs/glossary-user.md" <<'EOF'
### alpha
- **Definition**: line one of the definition
  line two of the definition
- **Related**: [owner](architecture/owner.md)
EOF
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "definition with one continuation line" 0
case_end

case_begin "definition-three-lines-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
cat >> "$REPO/docs/glossary-user.md" <<'EOF'
### alpha
- **Definition**: line one of the definition
  line two of the definition
  line three of the definition
- **Related**: [owner](architecture/owner.md)
EOF
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "definition spanning three lines" 1
expect_out "definition length reported" "BLOCK"
case_end

case_begin "missing-definition-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "entry without Definition" 1
case_end

case_begin "empty-definition-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Definition**:\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Definition with no text" 1
expect_out "empty definition reported" "BLOCK"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Definition**:   \n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Definition with only trailing whitespace" 1
case_end

case_begin "related-zero-links-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Definition**: a term.\n- **Related**: see the owner doc\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Related with no link" 1
case_end

case_begin "related-two-links-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Definition**: a term.\n- **Related**: [a](a.md), [b](b.md)\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Related with two links" 1
case_end

case_begin "related-todo-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Definition**: a term.\n- **Related**: TODO\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Related left as TODO" 1
case_end

case_begin "full-name-bullet-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### IR\n- **Full name**: intermediate representation\n- **Definition**: a term.\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Full name bullet present" 1
case_end

case_begin "level-bullet-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '### alpha\n- **Level**: 2\n- **Definition**: a term.\n- **Related**: [owner](architecture/owner.md)\n' >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "Level bullet present" 1
case_end

case_begin "cross-file-duplicate-blocks" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" alpha beta
gloss "$REPO/docs/glossary-internal.md" alpha gamma
stage "$REPO" docs/glossary-user.md docs/glossary-internal.md
run_gate "$REPO" --staged
expect_rc "same term in user and internal" 1
expect_out "duplicate term named" "alpha"
case_end

case_begin "nothing-staged-skips" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" beta alpha
commit_all "$REPO"
printf 'other\n' > "$REPO/other.txt"
stage "$REPO" other.txt
run_gate "$REPO" --staged
expect_rc "no glossary file staged (committed one is invalid)" 0
expect_out "skip reported" "SKIPPED"
case_end

case_begin "glossary-index-page-only-skips" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" beta alpha
commit_all "$REPO"
printf '# Glossary\n\n## User terms\n\nSee [user](glossary-user.md).\n' > "$REPO/docs/glossary.md"
stage "$REPO" docs/glossary.md
run_gate "$REPO" --staged
expect_rc "only docs/glossary.md staged" 0
expect_out "skip reported" "SKIPPED"
case_end

case_begin "foreign-glossary-name-ignored" "bin/review-doc-glossary"
new_repo
printf '# Glossary\n\n## Not an entry file\n\n### zeta\n### alpha\n' > "$REPO/docs/glossary-foo.md"
stage "$REPO" docs/glossary-foo.md
run_gate "$REPO" --staged
expect_rc "only docs/glossary-foo.md staged" 0
expect_out "skip reported" "SKIPPED"
gloss "$REPO/docs/glossary-user.md" alpha beta
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "glossary-foo.md beside a valid user file is not checked" 0
case_end

case_begin "range-split-valid-passes" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha mike
gloss "$REPO/docs/glossary-user-n-z.md" november zulu
stage "$REPO" docs/glossary-user-a-m.md docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "a-m + n-z with in-range terms" 0
case_end

case_begin "out-of-range-term-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha zeta
gloss "$REPO/docs/glossary-user-n-z.md" november
stage "$REPO" docs/glossary-user-a-m.md docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "zeta in the a-m file" 1
expect_out "out-of-range term named" "zeta"
case_end

case_begin "non-alpha-leading-terms-in-a-range-pass" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" 2fa _foo alpha
gloss "$REPO/docs/glossary-user-n-z.md" nu
stage "$REPO" docs/glossary-user-a-m.md docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "2fa and _foo in the range starting at a" 0
case_end

case_begin "non-alpha-leading-term-outside-a-range-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha
gloss "$REPO/docs/glossary-user-n-z.md" _foo nu
stage "$REPO" docs/glossary-user-a-m.md docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "_foo in the n-z file" 1
expect_out "out-of-range term named" "_foo"
case_end

case_begin "range-overlap-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha
gloss "$REPO/docs/glossary-user-m-z.md" zulu
stage "$REPO" docs/glossary-user-a-m.md docs/glossary-user-m-z.md
run_gate "$REPO" --staged
expect_rc "a-m and m-z overlap on m" 1
case_end

case_begin "range-gap-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-l.md" alpha
gloss "$REPO/docs/glossary-user-n-z.md" zulu
stage "$REPO" docs/glossary-user-a-l.md docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "a-l and n-z leave m uncovered" 1
case_end

case_begin "unsplit-and-ranged-coexist-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user.md" alpha
gloss "$REPO/docs/glossary-user-a-m.md" beta
gloss "$REPO/docs/glossary-user-n-z.md" zulu
stage "$REPO" docs/glossary-user.md docs/glossary-user-a-m.md docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "glossary-user.md beside a full ranged set" 1
case_end

case_begin "unparseable-name-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-foo.md" alpha
stage "$REPO" docs/glossary-user-foo.md
run_gate "$REPO" --staged
expect_rc "glossary-user-foo.md" 1
expect_out "unparseable file named" "glossary-user-foo.md"
case_end

case_begin "reversed-range-name-blocks" "bin/lib/glossary-format.js"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha
gloss "$REPO/docs/glossary-user-z-n.md" zulu
stage "$REPO" docs/glossary-user-a-m.md docs/glossary-user-z-n.md
run_gate "$REPO" --staged
expect_rc "from > to range name" 1
case_end

case_begin "partial-stage-checks-other-ranged-file-from-index" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" beta
gloss "$REPO/docs/glossary-user-n-z.md" aardvark nu
commit_all "$REPO"
gloss "$REPO/docs/glossary-user-a-m.md" beta charlie
stage "$REPO" docs/glossary-user-a-m.md
run_gate "$REPO" --staged
expect_rc "unstaged n-z in the index still violates" 1
expect_out "violation in the unstaged file named" "aardvark"
case_end

case_begin "partial-stage-reads-index-not-worktree-of-other-file" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" beta
gloss "$REPO/docs/glossary-user-n-z.md" nu
commit_all "$REPO"
gloss "$REPO/docs/glossary-user-n-z.md" aardvark nu
gloss "$REPO/docs/glossary-user-a-m.md" beta charlie
stage "$REPO" docs/glossary-user-a-m.md
run_gate "$REPO" --staged
expect_rc "unstaged worktree breakage in n-z is not read" 0
case_end

case_begin "index-wins-over-worktree" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" alpha beta
stage "$REPO" docs/glossary-user.md
gloss "$REPO/docs/glossary-user.md" beta alpha
run_gate "$REPO" --staged
expect_rc "valid index, broken worktree" 0
new_repo
gloss "$REPO/docs/glossary-user.md" beta alpha
stage "$REPO" docs/glossary-user.md
gloss "$REPO/docs/glossary-user.md" alpha beta
run_gate "$REPO" --staged
expect_rc "broken index, fixed worktree" 1
case_end

case_begin "staged-deletion-leaving-range-gap-blocks" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha mike
gloss "$REPO/docs/glossary-user-n-z.md" november zulu
commit_all "$REPO"
git -C "$REPO" rm -q docs/glossary-user-n-z.md
run_gate "$REPO" --staged
expect_rc "deleting n-z leaves a-m alone with n-z uncovered" 1
case_end

case_begin "staged-deletion-of-every-glossary-file-passes" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user-a-m.md" alpha mike
gloss "$REPO/docs/glossary-user-n-z.md" november zulu
gloss "$REPO/docs/glossary-internal.md" delta
commit_all "$REPO"
git -C "$REPO" rm -q docs/glossary-user-a-m.md docs/glossary-user-n-z.md docs/glossary-internal.md
run_gate "$REPO" --staged
expect_rc "no glossary file left in the index" 0
if [[ "$GATE_RC" != 127 && "$GATE_OUT" != *BLOCK* ]]; then pass "no BLOCK finding when the index holds no glossary file"
else fail "no BLOCK finding when the index holds no glossary file" "output: ${GATE_OUT:0:600}"; fi
case_end

case_begin "all-mode-is-advisory" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" beta alpha
run_gate "$REPO" --all
expect_rc "--all with an order violation" 0
expect_out "--all still reports the finding" "BLOCK"
case_end

case_begin "mode-selection-skips" "bin/review-doc-glossary"
new_repo
gloss "$REPO/docs/glossary-user.md" beta alpha
stage "$REPO" docs/glossary-user.md
run_gate "$REPO"
expect_rc "no mode selected" 0
expect_out "no-mode skip reported" "SKIPPED"
run_gate "$REPO" --staged --all
expect_rc "--staged and --all together" 0
expect_out "mutual-exclusion skip reported" "SKIPPED"
case_end

case_begin "deep-heading-before-first-entry-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '#### Stray deep heading\n\n' >> "$REPO/docs/glossary-user.md"
entry alpha >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "#### heading before the first entry" 1
expect_out "deep heading reported" "BLOCK"
case_end

case_begin "missing-h1-blocks" "bin/lib/glossary-format.js"
new_repo
printf 'Intro without a title.\n\n' > "$REPO/docs/glossary-user.md"
entry alpha >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "file without an H1" 1
expect_out "missing H1 reported" "H1"
case_end

case_begin "second-h1-blocks" "bin/lib/glossary-format.js"
new_repo
gloss_head "$REPO/docs/glossary-user.md"
printf '# Second title\n\n' >> "$REPO/docs/glossary-user.md"
entry alpha >> "$REPO/docs/glossary-user.md"
stage "$REPO" docs/glossary-user.md
run_gate "$REPO" --staged
expect_rc "file with two H1 lines" 1
expect_out "second H1 reported" "only one"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
