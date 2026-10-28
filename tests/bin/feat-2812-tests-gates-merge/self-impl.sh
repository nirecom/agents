# Tests: bin/check-test-frontmatter/self-impl.sh, bin/check-self-impl.sh
# Tags: TL2, bin, merge, tests-gates, self-impl, scope:issue-specific
# Self-implemented harness during a merge: a MERGE_HEAD-only file is judged against the MERGE_HEAD
# blob (R4), identical parents against that one blob (R5), and differing parents 3-way with the
# existing count H + M - B per (kind, detail) key (R6, accepted behaviours E1-E3).
# Sourced by tests/bin/feat-2812-tests-gates-merge.sh after fixture.sh and bodies.sh (sib, c<N>-*).
# Counter: a bash PASS=0 line.
# shellcheck shell=bash

echo ""
echo "=== self-implemented harness against the merge parents ==="

# si_merge <tag> <base-body|-> <up-body|-> <head-body|-> <staged-body> — a merge fixture for
# tests/bin/s.sh, then the frontmatter gate. "-" leaves the path out of that commit.
si_merge() {
  local tag="$1" rel=tests/bin/s.sh b u h
  b=""; u=""; h=""
  [ "$2" = "-" ] || b="$rel=$2"
  [ "$3" = "-" ] || u="$rel=$3"
  [ "$4" = "-" ] || h="$rel=$4"
  mergefx "$TMPBASE/si-$tag" "$b" "$u" "$h" "$rel=$5"
  gate "$TMPBASE/si-$tag" "$FG"
}

case_begin "r4-merge-head-file-counts-only-the-added-counter" "bin/check-test-frontmatter/self-impl.sh"
sib r4-up 1 up
sib r4-edit 2 up edited
si_merge r4 - r4-up - r4-edit
expect_rc "R4: MERGE_HEAD has 1 counter, staged 2" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "R4: only the added counter" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "r5-identical-parents-without-base-block-an-added-counter" "bin/check-test-frontmatter/self-impl.sh"
sib r5-same 1 same
sib r5-two 2 same edited
si_merge r5a - r5-same r5-same r5-two
expect_rc "R5 (a): both parents 1 counter, no base, staged 2" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "R5 (a)" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "r5-identical-parents-pass-an-unrelated-edit" "bin/check-test-frontmatter/self-impl.sh"
sib r5-edit 1 same edited
si_merge r5b - r5-same r5-same r5-edit
expect_rc "R5 (b): count kept, another line edited" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "R5 (b)" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
case_end

case_begin "r6-d-base1-head1-merge1-staged2-blocks" "bin/check-self-impl.sh"
si_merge d c1-b c1-m c1-h c2-hm
expect_rc "(d) B1 H1 M1 staged 2" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "(d)" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "r6-e-each-parent-added-one-counter-passes" "bin/check-self-impl.sh"
si_merge e c0-b c1-m c1-h c2-hm
expect_rc "(e) B0 H1 M1 staged 2 (each parent added one)" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "(e)" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
case_end

case_begin "r6-f-a-third-counter-blocks-once" "bin/check-self-impl.sh"
si_merge f c0-b c1-m c1-h c3-hm
expect_rc "(f) B0 H1 M1 staged 3" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "(f) only the counter beyond H+M-B=2" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "r6-g-counter-added-during-the-merge-passes-e2" "bin/check-self-impl.sh"
# E2 (accepted miss): M's counter line was dropped and one written during the merge; the count is H+M-B.
si_merge g c0-b c1-m c1-h c2-h
expect_rc "(g) B0 H1 M1 staged 2, one written in the merge" 0 "$GATE_RC" "$GATE_ALL"
case_end

case_begin "r6-h-counter-merge-head-removed-blocks-e3" "bin/check-self-impl.sh"
si_merge h c1-b c0-m c1-h c1-hm
expect_rc "(h) B1 H1 M0 staged 1 (E3)" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "(h)" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "r6-i-counter-head-removed-kept-blocks-e1" "bin/check-self-impl.sh"
si_merge i c1-b c1-m c0-h c1-hm
expect_rc "(i) B1 H0 M1 staged 1 (E1)" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "(i)" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

# Clamping (mirrors language-match.sh r6-clamped-*): base has two PASS=0 lines, each parent keeps one
# (blobs differ), so the existing count H + M - B = 1 + 1 - 2 = 0 clamps at 0 and one staged counter
# is added; with H = 2 the existing count is 2 + 1 - 2 = 1 and the same staged counter is kept.
sib c2-b 2 base

case_begin "r6-clamped-b2-h1-m1-staged-1-blocks" "bin/check-self-impl.sh"
si_merge cl1 c2-b c1-m c1-h c1-hm
expect_rc "(clamp) B2 H1 M1 staged 1 (1+1-2=0 existing)" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "(clamp) the one staged counter" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "r6-clamped-b2-h2-m1-staged-1-passes" "bin/check-self-impl.sh"
si_merge cl2 c2-b c1-m c2-h c1-hm
expect_rc "(clamp) B2 H2 M1 staged 1 (2+1-2=1 existing)" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "(clamp) B2 H2 M1" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
case_end

case_begin "r3-head-only-file-counts-only-the-added-counter" "bin/check-test-frontmatter/self-impl.sh"
sib r3-edit 2 h edited
si_merge r3 - - c1-h r3-edit
expect_rc "R3: only HEAD has the file (1 counter), staged 2" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "R3: only the added counter" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

# Two (kind, detail) keys: X = counter-init PASS=0, Y = counter-init FAIL=0. The 3-way existing
# count is per key; summing across keys would hide an X added while a Y shared by both parents stays.
skb() {
  local name="$1"
  shift
  raw "$name" "$(hdr bin/a.sh)" "$@" "$(mcase a bin/a.sh)"
}
skb k-b 'echo base'
skb k-hx 'PASS=0' 'echo h'
skb k-hxy 'PASS=0' 'FAIL=0' 'echo h'
skb k-my 'FAIL=0' 'echo m'
skb k-xy 'PASS=0' 'FAIL=0' 'echo h' 'echo m'
skb k-x2y 'PASS=0' 'PASS=0' 'FAIL=0' 'echo h' 'echo m'
X_HIGH="counter-init PASS=0)"
Y_HIGH="counter-init FAIL=0)"
# lines_with <text> <needle> — the number of lines of <text> containing <needle>.
lines_with() {
  local line n=0
  while IFS= read -r line; do
    case "$line" in *"$2"*) n=$((n + 1)) ;; esac
  done <<< "$1"
  printf '%s' "$n"
}
# expect_x_only <label> — exactly one HIGH, and it names key X, never key Y.
expect_x_only() {
  expect_rc "$1" 1 "$GATE_RC" "$GATE_ALL"
  expect_codes "$1" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
  assert_eq "$1: HIGH lines naming PASS=0=$(lines_with "$GATE_OUT" "$X_HIGH")" "$1: HIGH lines naming PASS=0=1"
  assert_eq "$1: HIGH lines naming FAIL=0=$(lines_with "$GATE_OUT" "$Y_HIGH")" "$1: HIGH lines naming FAIL=0=0"
}

case_begin "r6-two-keys-extra-x-blocks-on-x-only" "bin/check-self-impl.sh"
si_merge kx k-b k-my k-hx k-x2y
expect_x_only "two keys: B0, H has X, M has Y, staged X X Y"
case_end

case_begin "r6-two-keys-one-of-each-passes" "bin/check-self-impl.sh"
si_merge kxy k-b k-my k-hx k-xy
expect_rc "two keys: B0, H has X, M has Y, staged X Y" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "two keys: staged X Y" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
case_end

case_begin "r6-two-keys-shared-y-does-not-absorb-an-extra-x" "bin/check-self-impl.sh"
# Per key: X 1+0-0=1 < 2 (blocks), Y 1+1-0=2 >= 1. A cross-key sum (3 >= 3) would pass it.
si_merge kneg k-b k-my k-hxy k-x2y
expect_x_only "two keys: B0, H has X Y, M has Y, staged X X Y"
case_end
