#!/usr/bin/env bash
# Tests: skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md
# Tags: tl1, static, workflow, todowrite, roundtrip-reduction, skill-orchestration, scope:issue-specific, pwsh-not-required
#
# #1644 stage 3 (type 3 — SSOT de-duplication). The TodoWrite checklist step is a
# second, model-maintained copy of state that the workflow state store already owns,
# so it is removed from both entry skills. This file is written BEFORE the removal
# and is expected to be RED on C1 until the edit lands.
#
# TL3 gap (what this test does NOT catch):
# - Whether a live session still renders a usable step list after the checklist line
#   is gone (the state store, not the SKILL.md prose, is the source consulted).
# - Whether the renumbered labels still read coherently to the model at runtime.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

SELF="$(basename "${BASH_SOURCE[0]}")"

WI_MD="skills/workflow-init/SKILL.md"
CI_MD="skills/clarify-intent/SKILL.md"

# The call-site label each file carries TODAY. Stage 3 deletes these lines and
# renumbers the tail, so after the edit neither token may co-occur with the
# checklist tool name anywhere in the tree.
WI_OLD_LABEL='A4'
CI_OLD_LABEL='CI-C2'

# Assembled at runtime so this file's own grep patterns are not what the greps find.
TOOL="Todo""Write"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"
  else fail "$desc -- expected [$expected] got [$actual]"; fi
}

for f in "$WI_MD" "$CI_MD"; do
  [ -f "$f" ] || { echo "FATAL: source file missing: $f"; exit 2; }
done

echo "--- C1: the checklist call is gone from both entry skills ---"

# C1 is the gate that flips green on the removal commit. Literal (-F) match:
# any mention at all, prose or code, counts as "still there".
for f in "$WI_MD" "$CI_MD"; do
  HITS="$(grep -n -F "$TOOL" "$f" | tr '\n' ' ')"
  check "C1 $f contains no $TOOL reference" "" "$HITS"
done

echo ""
echo "--- C2: step labels stay a contiguous sequence after renumbering ---"

# Labels are enumerated FROM the file, never hardcoded, so the check keeps
# measuring contiguity if an unrelated future edit adds or drops a step.
# Letter-suffix sub-steps (A1a, CI-C1b) do not participate in the integer
# sequence per rules/prompt.md 4.2, but each must attach to a defined parent.

assert_contiguous() {
  local desc="$1" prefix="$2"
  shift 2
  local labels=("$@")
  local n=${#labels[@]}

  # Mutation guard: if the extraction regex ever stops matching, the two
  # assertions below would both pass on an empty set (a false green).
  if [ "$n" -lt 4 ]; then
    fail "$desc: extracted $n labels, expected at least 4 -- the label regex no longer matches the file"
    return
  fi
  pass "$desc: extracted $n labels (${labels[*]})"

  local dupes
  dupes="$(printf '%s\n' "${labels[@]}" | sort | uniq -d | tr '\n' ' ')"
  check "$desc: no duplicate label token" "" "$dupes"

  # min..max rather than 1..max: the two blocks do not share a first index
  # (Path A opens at A1, the Completion block opens at CI-C0).
  local ints min max got want
  ints="$(printf '%s\n' "${labels[@]}" | sed -E "s/^${prefix}([0-9]+)[a-z]?\$/\\1/")"
  min="$(printf '%s\n' "$ints" | sort -n | head -1)"
  max="$(printf '%s\n' "$ints" | sort -n | tail -1)"
  got="$(printf '%s\n' "$ints" | sort -n -u | tr '\n' ' ')"
  want="$(seq "$min" "$max" | tr '\n' ' ')"
  check "$desc: integer labels are $min..$max with no gap" "$want" "$got"

  # Orphaned sub-step: A3b surviving a deleted A3 is the same defect class as a gap.
  local orphans=""
  local l parent
  for l in "${labels[@]}"; do
    case "$l" in
      *[a-z]) parent="${l%[a-z]}" ;;
      *) continue ;;
    esac
    printf '%s\n' "${labels[@]}" | grep -qx -- "$parent" || orphans="$orphans$l "
  done
  check "$desc: every letter-suffix sub-step has a defined integer parent" "" "$orphans"
}

mapfile -t WI_LABELS < <(grep -oE '^- A[0-9]+[a-z]?\.' "$WI_MD" | sed 's/^- //; s/\.$//')
assert_contiguous "C2a $WI_MD Path A" "A" "${WI_LABELS[@]}"

mapfile -t CI_LABELS < <(grep -oE '^CI-C[0-9]+[a-z]?\.' "$CI_MD" | sed 's/\.$//')
assert_contiguous "C2b $CI_MD Completion" "CI-C" "${CI_LABELS[@]}"

echo ""
echo "--- C3: nothing outside the two skills is left pinned to the removed call ---"

# `scripts/` is searched when present (it is a per-skill subdirectory in this repo,
# not a root-level tree); `skills/` and `tests/` must exist or the greps below
# would report "clean" by searching nothing.
SEARCH_ROOTS=(skills scripts tests)
EXISTING_ROOTS=()
for r in "${SEARCH_ROOTS[@]}"; do [ -d "$r" ] && EXISTING_ROOTS+=("$r"); done
MISSING_REQUIRED=""
for r in skills tests; do [ -d "$r" ] || MISSING_REQUIRED="$MISSING_REQUIRED$r "; done
check "C3 precondition: required search roots exist" "" "$MISSING_REQUIRED"

# C3a — no third-party file names the old label and the checklist tool on the
# same line. Such a line documents "the checklist fires at A4 / CI-C2", which
# stops being true the moment the line is deleted and the tail renumbers.
CO_OCCUR="$(grep -rnE "(${WI_OLD_LABEL}\.|${CI_OLD_LABEL}\.)" \
  --include='*.md' --include='*.sh' --include='*.js' \
  --exclude="$SELF" --exclude-dir=_archive \
  "${EXISTING_ROOTS[@]}" 2>/dev/null \
  | grep -F "$TOOL" \
  | grep -v -e "^$WI_MD:" -e "^$CI_MD:" | tr '\n' ' ')"
check "C3a no file outside the two skills ties the old label to the $TOOL call" "" "$CO_OCCUR"

# C3b — the silent-break class C3a cannot see: a file that asserts on the
# checklist line's CONTENT without quoting its label. Scoped to files that also
# name one of the two owning skills, so an unrelated future $TOOL user is not
# swept in (CPR-UNV: the invariant is about coupling, not about the tool).
COUPLED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in "$WI_MD"|"$CI_MD") continue ;; esac
  if grep -qE 'workflow-init|clarify-intent' "$f"; then
    COUPLED="$COUPLED$f "
  fi
done < <(grep -rl -F "$TOOL" \
  --include='*.md' --include='*.sh' --include='*.js' \
  --exclude="$SELF" --exclude-dir=_archive \
  "${EXISTING_ROOTS[@]}" 2>/dev/null | sort)
check "C3b no workflow-init/clarify-intent-coupled file still references $TOOL" "" "$COUPLED"

# C3c — renumber integrity across files. Deleting CI-C2 shifts CI-C3 down to
# CI-C2; any outside pointer left at the old number now names a step that
# either does not exist or means something else. CI-C* is namespaced enough to
# grep safely (bare A4/A5 is not, which is why C3a scopes those by co-occurrence).
DEFINED_CI="$(printf '%s\n' "${CI_LABELS[@]}" | sort -u)"
DANGLING=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  printf '%s\n' "$DEFINED_CI" | grep -qx -- "$ref" || DANGLING="$DANGLING$ref "
done < <(grep -rhoE 'CI-C[0-9]+[a-z]?' \
  --include='*.md' --include='*.sh' --include='*.js' \
  --exclude="$SELF" --exclude-dir=_archive \
  "${EXISTING_ROOTS[@]}" 2>/dev/null \
  | sort -u)
check "C3c every CI-C* label referenced anywhere is defined in $CI_MD" "" "$DANGLING"

echo ""
echo "=== feature-1644-todowrite-removal: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
