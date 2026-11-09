#!/usr/bin/env bash
# tests/skills/feature-2473-migrate-subskills-skill.sh
# Tests: skills/migrate-tests/SKILL.md, skills/migrate-issues/SKILL.md, skills/migrate-tracker/SKILL.md
# Tags: TL2, skills, migrate, scope:issue-specific
# Issue #2473: each migrate sub-skill's first step runs its own scripts/needs.js and ends with
# "done" on exit 0 (C3); /migrate-tests MTS-3 runs scripts/apply-section.sh, confirms through
# AskUserQuestion on its exit 3 and re-runs the write after bin/repo-settings --reset-malformed (B1).
# apply-section.sh behavior: tests/skills/feature-2473-migrate-tests-apply-section.sh.
# TL3 gap: a model actually following the prompt; here the text is checked.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "${TMPBASE:?}"' EXIT
harness_isolate "$TMPBASE/iso"

SKILLS_DIR="$SCRIPT_CHECKOUT_ROOT/skills"

# The first numbered step (<PREFIX>-1) up to the next step with the same prefix.
FIRST_STEP_AWK=""
read -r -d '' FIRST_STEP_AWK <<'AWK' || true
!p && match($0, /^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]+)?\**[A-Z]+-1[.:)]/) {
  s = substr($0, RSTART, RLENGTH); gsub(/[^A-Z-]/, "", s); sub(/-$/, "", s); p = s "-"; on = 1; print; next
}
on && $0 ~ ("^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]+)?\\**" p "[0-9]+") { exit }
on { print }
AWK
# Step <want> (e.g. MTS-3) up to the next step with the same prefix <p> or the next "## " heading.
STEP_AWK=""
read -r -d '' STEP_AWK <<'AWK' || true
/^## / { on = 0 }
{ opens = ($0 ~ ("^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]+)?\\**" p "[0-9]+")) }
opens { on = ($0 ~ ("^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]+)?\\**" want "[^0-9]")) }
on { print }
AWK

first_step() {
  local md="$SKILLS_DIR/${1:?}/SKILL.md"
  [[ -f "$md" ]] || return 0
  awk "$FIRST_STEP_AWK" "$md"
}
step() { awk -v want="${2:?}" -v p="${2%-*}-" "$STEP_AWK" "${1:?}"; }
has() { grep -Eqi -- "$2" <<<"$1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }
DONE_RE='exit (code )?0[^.]*(means|=>|->)[^.]*(done|success|already)[^.]*(and )?(end|stop)'

case_begin "C3-migrate-tests-first-step-needs" "skills/migrate-tests/SKILL.md"
S1="$(first_step migrate-tests)"
check "migrate-tests first step exists" '[[ -n "$S1" ]]'
check "migrate-tests first step runs skills/migrate-tests/scripts/needs.js" 'has "$S1" "skills/migrate-tests/scripts/needs\\.js"' "$S1"
check "migrate-tests first step: exit 0 -> report done and end" 'has "$S1" "$DONE_RE"' "$S1"
case_end

case_begin "C3-migrate-issues-first-step-needs" "skills/migrate-issues/SKILL.md"
S1="$(first_step migrate-issues)"
check "migrate-issues first step exists" '[[ -n "$S1" ]]'
check "migrate-issues first step runs skills/migrate-issues/scripts/needs.js" 'has "$S1" "skills/migrate-issues/scripts/needs\\.js"' "$S1"
check "migrate-issues first step: exit 0 -> report done and end" 'has "$S1" "$DONE_RE"' "$S1"
case_end

case_begin "C3-migrate-tracker-first-step-needs" "skills/migrate-tracker/SKILL.md"
S1="$(first_step migrate-tracker)"
check "migrate-tracker first step exists" '[[ -n "$S1" ]]'
check "migrate-tracker first step runs skills/migrate-tracker/scripts/needs.js" 'has "$S1" "skills/migrate-tracker/scripts/needs\\.js"' "$S1"
check "migrate-tracker first step: exit 0 -> report done and end" 'has "$S1" "$DONE_RE"' "$S1"
case_end

case_begin "B1-migrate-tests-reset-malformed" "skills/migrate-tests/SKILL.md"
MTS_MD="$SKILLS_DIR/migrate-tests/SKILL.md"
S3="$(step "$MTS_MD" MTS-3)"
check "MTS-3 exists and runs skills/migrate-tests/scripts/apply-section.sh" 'has "$S3" "skills/migrate-tests/scripts/apply-section\\.sh"' "$S3"
check "MTS-3 passes --no-push to apply-section.sh" 'has "$S3" "apply-section\\.sh[^.]*--no-push"' "$S3"
check "MTS-3 names the refusal for a file that is not JSON / does not hold an object" 'has "$S3" "not JSON|not hold an object|malformed"' "$S3"
check "MTS-3 ties that refusal to exit 3" 'has "$S3" "exit 3"' "$S3"
check "MTS-3 confirms through AskUserQuestion before resetting" 'has "$S3" "AskUserQuestion"' "$S3"
check "MTS-3 resets with bin/repo-settings --root <ROOT> --reset-malformed" 'has "$S3" "bin/repo-settings[^.]*--root[^.]*--reset-malformed"' "$S3"
check "MTS-3 re-runs the same write after the reset" 'has "$S3" "--reset-malformed[^.]*(then )?re-?run[^.]*(same )?write|re-?run[^.]*same write"' "$S3"
check "MTS-3 stops on any other non-zero exit" 'has "$S3" "other non-zero[^.]*(show|stop)"' "$S3"
check "MTS-4 does not open a step" '[[ -z "$(step "$MTS_MD" MTS-4)" ]]' "$(step "$MTS_MD" MTS-4)"
check "migrate-tests names --replace-malformed nowhere" '! grep -q -- "--replace-malformed" "$MTS_MD"' "$(grep -n -- '--replace-malformed' "$MTS_MD" || true)"
case_end

case_begin "MTS-confirm-and-dry-run" "skills/migrate-tests/SKILL.md"
MTS_MD="$SKILLS_DIR/migrate-tests/SKILL.md"
S2="$(step "$MTS_MD" MTS-2)"
check "MTS-2 runs detect.js" 'has "$S2" "skills/migrate-tests/scripts/detect\\.js"' "$S2"
check "MTS-2 confirms the proposal through AskUserQuestion" 'has "$S2" "AskUserQuestion"' "$S2"
check "MTS-2 confirms categorization, testHarness and caseMarker" 'has "$S2" "categorization" && has "$S2" "testHarness" && has "$S2" "caseMarker"' "$S2"
DRY_LINE="$(grep -E -- '--dry-run' "$MTS_MD" || true)"
check "--dry-run runs MTS-1 and MTS-2, then skips MTS-3" 'has "$DRY_LINE" "MTS-1[^.]*MTS-2[^.]*skips? .?MTS-3"' "$DRY_LINE"
check "no step after MTS-3 is referenced anywhere" '! grep -Eq "MTS-([4-9]|[1-9][0-9])" "$MTS_MD"' "$(grep -nE 'MTS-([4-9]|[1-9][0-9])' "$MTS_MD" || true)"
case_end

# rules/prompt.md 1.3 caps an inlined procedure at 3 steps; a re-inline is caught here as well as
# by the commit gate.
case_begin "MTS-procedure-step-limit" "skills/migrate-tests/SKILL.md"
MTS_MD="$SKILLS_DIR/migrate-tests/SKILL.md"
MTS_LABELS="$(awk '/^## Procedure/ { on = 1; next } /^## / { on = 0 } on' "$MTS_MD" | grep -Eo 'MTS-[0-9]+[a-z]?' | sort -u | grep -c '' || true)"
check "Procedure holds 1 to 3 distinct MTS-N labels" '[[ "$MTS_LABELS" -ge 1 && "$MTS_LABELS" -le 3 ]]' "got $MTS_LABELS"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
