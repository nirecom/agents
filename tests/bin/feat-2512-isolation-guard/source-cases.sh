# Source-inheritance cases for feat-2512-isolation-guard.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

c_i2_pinned_parent() {
  local r
  r="$(new_root i2)"
  fx "$r/hooks/good/parent.sh" '#!/usr/bin/env bash' 'source "$(dirname "$0")/../lib/harness.sh"' \
    'harness_isolate "$(make_tmp)"' '. "$(dirname "$0")/child.sh"'
  fx "$r/hooks/good/child.sh" "$EXEC_RO"
  fx "$r/hooks/bad/parent.sh" '#!/usr/bin/env bash' '. "$(dirname "$0")/child.sh"'
  fx "$r/hooks/bad/child.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "I2 a child sourced after harness_isolate inherits the pin" no_violation_for "hooks/good/child.sh"
  expect "I2 a child of an unpinned parent is a violation" violation_for "hooks/bad/child.sh"
  expect "I2 rc=1 because of the unpinned parent's child" rc_is 1
}

c_i3_two_parents_one_unpinned() {
  local r
  r="$(new_root i3)"
  fx "$r/hooks/pinned.sh" '#!/usr/bin/env bash' "$PIN_BOTH" '. "$(dirname "$0")/shared/child.sh"'
  fx "$r/hooks/unpinned.sh" '#!/usr/bin/env bash' '. "$(dirname "$0")/shared/child.sh"'
  fx "$r/hooks/shared/child.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "I3 rc=1 when one of two parents is unpinned" rc_is 1
  expect "I3 the shared child is a violation" violation_for "hooks/shared/child.sh"
}

c_i17_same_name_helpers() {
  local r
  r="$(new_root i17)"
  fx "$r/hooks/a/main.sh" '#!/usr/bin/env bash' "$PIN_BOTH" '. "${BASH_SOURCE%/*}/helpers.sh"'
  fx "$r/hooks/a/helpers.sh" "$EXEC_RO"
  fx "$r/hooks/b/helpers.sh" "$EXEC_RO"
  fx "$r/hooks/c/main.sh" '#!/usr/bin/env bash' '. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"'
  fx "$r/hooks/c/helpers.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "I17 a/helpers.sh inherits from its pinned parent" no_violation_for "hooks/a/helpers.sh"
  expect "I17 b/helpers.sh (no parent) is a violation" violation_for "hooks/b/helpers.sh"
  expect "I17 c/helpers.sh (unpinned parent) is a violation" violation_for "hooks/c/helpers.sh"
}

c_i18_unresolvable_source() {
  local r
  r="$(new_root i18)"
  fx "$r/hooks/loop.sh" '#!/usr/bin/env bash' "$PIN_BOTH" \
    'for f in "$(dirname "$0")"/parts/*.sh; do source "$f"; done' \
    '. "$UNDEFINED_DIR_2512/undef-child.sh"' '. "$(dirname "$0")/missing/nowhere.sh"'
  fx "$r/hooks/parts/loop-child.sh" "$EXEC_RO"
  fx "$r/hooks/undef-child.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "I18 a child sourced from a loop does not inherit" violation_for "hooks/parts/loop-child.sh"
  expect "I18 a child sourced via an undefined variable does not inherit" violation_for "hooks/undef-child.sh"
  expect "I18 a missing source path is not itself reported as the parent's violation" no_violation_for "hooks/loop.sh"
}

c_i19_script_dir_variable() {
  local r
  r="$(new_root i19)"
  fx "$r/hooks/once/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" \
    'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"' 'source "$SCRIPT_DIR/lib.sh"'
  fx "$r/hooks/once/lib.sh" "$EXEC_RO"
  fx "$r/hooks/twice/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" \
    'SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"' 'SCRIPT_DIR="$SCRIPT_DIR/other"' 'source "$SCRIPT_DIR/lib.sh"'
  fx "$r/hooks/twice/lib.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "I19 a once-assigned SCRIPT_DIR resolves and the child inherits" no_violation_for "hooks/once/lib.sh"
  expect "I19 a twice-assigned variable does not resolve (child flagged)" violation_for "hooks/twice/lib.sh"
}

c_i23_source_before_pin() {
  local r
  r="$(new_root i23)"
  fx "$r/hooks/early/parent.sh" '#!/usr/bin/env bash' 'source "$(dirname "$0")/../lib/harness.sh"' \
    '. "$(dirname "$0")/child.sh"' 'harness_isolate "$(make_tmp)"'
  fx "$r/hooks/early/child.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "I23 rc=1 when the parent pins after sourcing" rc_is 1
  expect "I23 the child sourced before the pin is a violation" violation_for "hooks/early/child.sh"
}

# Plan step 2: ancestors are followed recursively (grandparent -> parent -> grandchild).
c_grandchild_inherits() {
  local r d
  r="$(new_root grandchild)"
  fx "$r/hooks/pinned/gp.sh" '#!/usr/bin/env bash' "$PIN_BOTH" '. "$(dirname "$0")/mid/parent.sh"'
  fx "$r/hooks/unpinned/gp.sh" '#!/usr/bin/env bash' '. "$(dirname "$0")/mid/parent.sh"'
  for d in pinned unpinned; do
    fx "$r/hooks/$d/mid/parent.sh" '. "$(dirname "${BASH_SOURCE[0]}")/leaf/grandchild.sh"'
    fx "$r/hooks/$d/mid/leaf/grandchild.sh" "$EXEC_RO"
  done
  run_cls --root "$r"
  expect "grandchild: a pinned grandparent covers the grandchild" no_violation_for "hooks/pinned/mid/leaf/grandchild.sh"
  expect "grandchild: an unpinned grandparent leaves the grandchild a violation" \
    violation_for "hooks/unpinned/mid/leaf/grandchild.sh"
  expect "grandchild: rc=1 because of the unpinned tree" rc_is 1
}

# Plan step 2: a source cycle is cut, so the scan ends and still classifies.
c_source_cycle() {
  local r
  r="$(new_root cycle)"
  fx "$r/hooks/open/a.sh" '#!/usr/bin/env bash' '. "$(dirname "$0")/b.sh"'
  fx "$r/hooks/open/b.sh" '. "$(dirname "${BASH_SOURCE[0]}")/a.sh"' "$EXEC_RO"
  fx "$r/hooks/closed/a.sh" '#!/usr/bin/env bash' "$PIN_BOTH" '. "$(dirname "$0")/b.sh"'
  fx "$r/hooks/closed/b.sh" '. "$(dirname "${BASH_SOURCE[0]}")/a.sh"' "$EXEC_RO"
  run_cls --root "$r"
  expect "cycle: the scan terminates (rc is 1, not a timeout)" rc_is 1
  expect "cycle: an unpinned A<->B cycle flags B" violation_for "hooks/open/b.sh"
  expect "cycle: a cycle whose head is pinned does not flag B" no_violation_for "hooks/closed/b.sh"
}

# Plan step 2 + I23: an edge carries the pin only when the source line follows the
# pin, at every level. The grandparent sources before it pins, so nothing is inherited.
c_grandparent_pin_late() {
  local r
  r="$(new_root gp-late)"
  fx "$r/hooks/gpl/gp.sh" '#!/usr/bin/env bash' '. "$(dirname "$0")/parent.sh"' "$PIN_BOTH"
  fx "$r/hooks/gpl/parent.sh" '. "$(dirname "${BASH_SOURCE[0]}")/grandchild.sh"'
  fx "$r/hooks/gpl/grandchild.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "gp pin late: rc=1" rc_is 1
  expect "gp pin late: the grandchild does not inherit a late pin" violation_for "hooks/gpl/grandchild.sh"
}

# Stage-4 rule-gap fix: a dir variable built from another resolvable variable, and a
# path after a `$(cd … && pwd)` subshell, both resolve; a variable cycle does not.
c_composed_dir_variables() {
  local r
  r="$(new_root composed)"
  fx "$r/hooks/chain/parent.sh" '#!/usr/bin/env bash' 'ROOT_2512="$(cd "$(dirname "$0")/.." && pwd)"' \
    "$PIN_BOTH" 'SUITE_2512="$ROOT_2512/chain/suite"' '. "$SUITE_2512/child.sh"'
  fx "$r/hooks/chain/suite/child.sh" "$EXEC_RO"
  fx "$r/hooks/after/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" \
    'SUB_2512="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sub"' 'source "$SUB_2512/child.sh"'
  fx "$r/hooks/after/sub/child.sh" "$EXEC_RO"
  fx "$r/hooks/loop/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" \
    'A_2512="$B_2512/x"' 'B_2512="$A_2512/y"' '. "$A_2512/child.sh"'
  fx "$r/hooks/loop/child.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "composed: a variable built from a resolvable variable carries the pin" no_violation_for "hooks/chain/suite/child.sh"
  expect "composed: a path after a cd-pwd subshell carries the pin" no_violation_for "hooks/after/sub/child.sh"
  expect "composed: a variable cycle resolves to nothing (child flagged)" violation_for "hooks/loop/child.sh"
}

case_begin "source-composed-dir-variables" "bin/check-plans-dir-isolation.sh"
c_composed_dir_variables
case_end

# Lexer nest fix: a `"` inside a single-quoted word inside "$( … )" must not end the outer
# quote, or the next line is lexed as quoted text and its source/exec goes unseen.
c_nested_quote_in_substitution() {
  local r q
  q="x=\"\$(printf '%s \"q' a)\""
  r="$(new_root nestq)"
  fx "$r/hooks/nq/exec.sh" '#!/usr/bin/env bash' "$q" "$EXEC_RO"
  fx "$r/hooks/nq/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" "$q" '. "$(dirname "$0")/child.sh"'
  fx "$r/hooks/nq/child.sh" "$EXEC_RO"
  run_cls --root "$r"
  expect "nested quote: the exec on the next line is still seen" label_hits STATE-UNPINNED "hooks/nq/exec.sh"
  expect "nested quote: the source on the next line still carries the pin" no_violation_for "hooks/nq/child.sh"
}

case_begin "lexer-nested-quote-in-substitution" "bin/check-plans-dir-isolation.sh"
c_nested_quote_in_substitution
case_end

# `# isolation: inherits-from <parent>`: the edge exists only when the parent is scanned and
# its code (not a comment) names the child's basename, and it sits at that first mention.
c_declared_parent() {
  local r d
  r="$(new_root declared)"
  d="$r/hooks/decl"
  fx "$d/ok/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" 'for p in alpha; do bash "$(dirname "$0")/kids/$p.sh"; done'
  fx "$d/ok/kids/alpha.sh" '# isolation: inherits-from ../parent.sh' "$EXEC_RO"
  fx "$d/gone/kids/beta.sh" '# isolation: inherits-from ../parent.sh' "$EXEC_RO"
  fx "$d/silent/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" 'echo nothing'
  fx "$d/silent/kids/gamma.sh" '# isolation: inherits-from ../parent.sh' "$EXEC_RO"
  fx "$d/comment/parent.sh" '#!/usr/bin/env bash' "$PIN_BOTH" '# runs delta via the loop below' 'true'
  fx "$d/comment/kids/delta.sh" '# isolation: inherits-from ../parent.sh' "$EXEC_RO"
  fx "$d/late/parent.sh" '#!/usr/bin/env bash' 'for p in epsilon; do bash "$(dirname "$0")/kids/$p.sh"; done' "$PIN_BOTH"
  fx "$d/late/kids/epsilon.sh" '# isolation: inherits-from ../parent.sh' "$EXEC_RO"
  fx "$d/bare/parent.sh" '#!/usr/bin/env bash' 'for p in zeta; do bash "$(dirname "$0")/kids/$p.sh"; done'
  fx "$d/bare/kids/zeta.sh" '# isolation: inherits-from ../parent.sh' "$EXEC_RO"
  run_cls --root "$r"
  expect "declared: a mentioned child of a pinned parent inherits" no_violation_for "hooks/decl/ok/kids/alpha.sh"
  expect "declared: a missing parent gives no edge" violation_for "hooks/decl/gone/kids/beta.sh"
  expect "declared: a parent that never names the child gives no edge" violation_for "hooks/decl/silent/kids/gamma.sh"
  expect "declared: a mention only in a comment gives no edge" violation_for "hooks/decl/comment/kids/delta.sh"
  expect "declared: a pin after the mention is not inherited" violation_for "hooks/decl/late/kids/epsilon.sh"
  expect "declared: an unpinned parent passes nothing down" violation_for "hooks/decl/bare/kids/zeta.sh"
  expect "declared: rc=1 for the broken declarations" rc_is 1
}

case_begin "source-declared-parent" "bin/check-plans-dir-isolation.sh"
c_declared_parent
case_end
