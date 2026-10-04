#!/usr/bin/env bash
# tests/skills/feat-2490-gate-trigger-uniformity.sh
# Tests: skills/_shared/confirm-plan.md, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/update-docs/SKILL.md, skills/worktree-start/SKILL.md
# Tags: tl2, static, confirm-gate, skill-prompt, scope:issue-specific, pwsh-not-required
# #2490 (c): the seven gate sections share one trigger line and no longer probe bin/confirm-off.

# TL3 gap (what this test does NOT catch): whether a live model actually runs
# next-step --gate at the trigger line and obeys GATE_ACTION instead of guessing.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh
# category: skill-orchestration.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

# Worktree copies (LOCAL_SKILL_MD semantics): the state under test, never ~/.claude.
SK="$AGENTS_DIR/skills"
CPA="$SK/_shared/confirm-plan.md"
CI="$SK/clarify-intent/SKILL.md"; MOP="$SK/make-outline-plan/SKILL.md"
MDP="$SK/make-detail-plan/SKILL.md"; WT="$SK/write-tests/SKILL.md"
WCD="$SK/write-code/SKILL.md"; UD="$SK/update-docs/SKILL.md"; WS="$SK/worktree-start/SKILL.md"
TRIGGER='Gate check: apply skills/_shared/confirm-plan.md CPA-3 — run next-step --gate and follow GATE_ACTION.'

check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
count_fixed() { grep -cF -- "$1" "$2" 2>/dev/null || true; }

# section <file> <ID>: from the first line whose head (after blanks, ** or #) is
# "<ID>." / "<ID>:" / "<ID> ", up to (not including) the next step-ID line or "## ".
# Each awk fragment stays on one line so check-case-markers can split cases safely.
AWK_HEAD='function head(s) { sub(/^[[:space:]]*/, "", s); sub(/^\*\*/, "", s); sub(/^#+[[:space:]]*/, "", s); return s }'
AWK_ISID='function is_id(s) { return s ~ /^[A-Z]+-[0-9]+[a-z]?([.:]|[[:space:]]|$)/ }'
AWK_BODY='{ h = head($0); if (on) { if ($0 ~ /^## / || is_id(h)) exit; print; next } if (index(h, id) == 1 && substr(h, length(id) + 1, 1) ~ /^[.: ]$/) { on = 1; print } }'
section() { awk -v id="$2" "$AWK_HEAD $AWK_ISID $AWK_BODY" "$1"; }
sec_count() { printf '%s\n' "$1" | grep -cF -- "$2" || true; }

echo "=== trigger line: one fixed string, exactly once per gate skill ==="
case_begin "trigger-line-once-per-skill" "skills/clarify-intent/SKILL.md"
for f in "$CI" "$MOP" "$MDP" "$WT" "$WCD" "$UD" "$WS"; do
  check "${f#"$SK"/}: trigger line exactly once" 1 "$(count_fixed "$TRIGGER" "$f")"
done
case_end

echo "=== CPA-3 owns the --gate protocol ==="
case_begin "cpa3-gate-protocol" "skills/_shared/confirm-plan.md"
S="$(section "$CPA" CPA-3)"
check "CPA-3 section extracted (non-empty)" yes "$([ -n "$S" ] && echo yes || echo no)"
check "CPA-3 runs next-step --gate" yes "$([ "$(sec_count "$S" 'next-step" --gate')" -ge 1 ] && echo yes || echo no)"
check "CPA-3 names --scope-change-approved" yes "$([ "$(sec_count "$S" '--scope-change-approved')" -ge 1 ] && echo yes || echo no)"
for v in proceed ask present-and-stop none; do
  check "CPA-3 names GATE_ACTION value $v" yes "$([ "$(sec_count "$S" "\`$v\`")" -ge 1 ] && echo yes || echo no)"
done
check "CPA-3 has a display-only GATE_CONFIRM_ line" yes \
  "$(printf '%s\n' "$S" | grep -F 'GATE_CONFIRM_' | grep -qiE 'display|表示' && echo yes || echo no)"
case_end

echo "=== gate sections: non-empty, carry the trigger, zero bin/confirm-off ==="
case_begin "gate-sections-no-confirm-off" "skills/write-tests/SKILL.md"
for pair in "$CI:CI-5" "$MOP:MOP-8" "$MDP:MDP-7" "$WT:WT-8" "$WCD:WCD-6" "$UD:UD-5" "$WS:WS-7" "$CPA:CPA-3"; do
  f="${pair%:*}"; id="${pair##*:}"; S="$(section "$f" "$id")"
  check "$id: section extracted (non-empty)" yes "$([ -n "$S" ] && echo yes || echo no)"
  if [ "$id" = "CPA-3" ]; then needle="--gate"; else needle="$TRIGGER"; fi
  check "$id: section carries the trigger" yes "$([ "$(sec_count "$S" "$needle")" -ge 1 ] && echo yes || echo no)"
  check "$id: zero bin/confirm-off" 0 "$(sec_count "$S" 'bin/confirm-off')"
done
case_end

echo "=== CI-2 stays on confirm-off (explicit exclusion, positive control) ==="
case_begin "ci2-keeps-confirm-off" "skills/clarify-intent/SKILL.md"
S="$(section "$CI" CI-2)"
check "CI-2 section extracted (non-empty)" yes "$([ -n "$S" ] && echo yes || echo no)"
check "CI-2 still probes confirm-off CONFIRM_OUTLINE once" 1 "$(sec_count "$S" 'confirm-off" CONFIRM_OUTLINE')"
case_end

echo "=== write-tests: no WT-8 confirm-off note outside the section ==="
case_begin "write-tests-note-migrated" "skills/write-tests/SKILL.md"
check "no line carries both WT-8 and confirm-off" 0 "$(grep -F 'WT-8' "$WT" | grep -cF 'confirm-off' || true)"
case_end

echo "=== make-detail-plan: gate before CONV_LANG, detector folded into --gate ==="
case_begin "mdp7-order-and-scope-change" "skills/make-detail-plan/SKILL.md"
T_LN="$(grep -nF -- "$TRIGGER" "$MDP" | head -n 1 | cut -d: -f1)"
C_LN="$(grep -nF 'CONV_LANG' "$MDP" | head -n 1 | cut -d: -f1)"
check "trigger line found" yes "$([ -n "$T_LN" ] && echo yes || echo no)"
check "CONV_LANG line found" yes "$([ -n "$C_LN" ] && echo yes || echo no)"
check "trigger line precedes the first CONV_LANG line" yes \
  "$([ -n "$T_LN" ] && [ -n "$C_LN" ] && [ "$T_LN" -lt "$C_LN" ] && echo yes || echo no)"
check "no direct detect-scope-change call" 0 "$(count_fixed 'detect-scope-change' "$MDP")"
check "MDP-7 names --scope-change-approved" yes \
  "$([ "$(sec_count "$(section "$MDP" MDP-7)" '--scope-change-approved')" -ge 1 ] && echo yes || echo no)"
case_end

echo "=== worktree-start: --headless exception line ==="
case_begin "worktree-start-headless-exception" "skills/worktree-start/SKILL.md"
S="$(section "$WS" WS-7)"
check "WS-7 has the --headless skip-the-gate-check line" yes \
  "$(printf '%s\n' "$S" | grep -F -- '--headless' | grep -qF 'skip the gate check' && echo yes || echo no)"
check "the --headless line resolves to proceed" yes \
  "$(printf '%s\n' "$S" | grep -F 'skip the gate check' | grep -qF 'proceed' && echo yes || echo no)"
case_end

# branch <section-text> <value>: from the line naming `GATE_ACTION=<value>` up to the next
# line naming any other `GATE_ACTION=` value (or the section end).
AWK_BRANCH='{ if (on && index($0, "GATE_ACTION=") && !index($0, tag)) exit; if (index($0, tag)) on = 1; if (on) print }'
branch() { printf '%s\n' "$1" | awk -v tag="\`GATE_ACTION=$2\`" "$AWK_BRANCH"; }
# branch_ok <file> <ID> <value> <marker>: yes when that branch exists in the section and carries its marker.
branch_ok() {
  local b; b="$(branch "$(section "$1" "$2")" "$3")"
  if [ -n "$b" ] && [ "$(sec_count "$b" "$4")" -ge 1 ]; then echo yes; else echo no; fi
}
# CI-5 is the one gate section whose OFF branch is delegated to CPA-3 instead of spelled out.
CI_DELEGATION='Apply the rest of the `skills/_shared/confirm-plan.md` protocol using `CONFIRM_INTENT`.'
ci_proceed_ok() {
  local s; s="$(section "$1" CI-5)"
  if [ "$(sec_count "$s" "$CI_DELEGATION")" -ge 1 ] && [ "$(sec_count "$s" '`GATE_ACTION=proceed`')" -eq 0 ]; then echo yes; else echo no; fi
}
# cpa_def_ok <file> <value> <marker>: CPA-3 defines `<value>` once, as a bullet carrying <marker>.
cpa_def_ok() {
  local d; d="$(section "$1" CPA-3 | grep -E -- "^- \`$2\`( \([^)]*\))?:")"
  if [ "$(sec_count "$d" "- \`$2\`")" -eq 1 ] && [ "$(sec_count "$d" "$3")" -ge 1 ]; then echo yes; else echo no; fi
}
file_of() {
  case "$1" in
    CI-5) echo "$CI" ;; MOP-8) echo "$MOP" ;; MDP-7) echo "$MDP" ;; WT-8) echo "$WT" ;;
    WCD-6) echo "$WCD" ;; UD-5) echo "$UD" ;; WS-7) echo "$WS" ;; *) echo "" ;;
  esac
}

echo "=== each gate section names both the proceed (OFF) and the ask (ON) branch ==="
case_begin "gate-sections-name-both-branches" "skills/make-outline-plan/SKILL.md"
# Rows: id|proceed marker|ask marker — the marker is what makes each branch the OFF / ON one.
while IFS='|' read -r id pm am; do
  f="$(file_of "$id")"
  check "$id: section carries the trigger" yes "$([ "$(sec_count "$(section "$f" "$id")" "$TRIGGER")" -ge 1 ] && echo yes || echo no)"
  if [ "$pm" = "DELEGATED" ]; then
    check "$id: OFF branch delegated to CPA-3 proceed" yes "$(ci_proceed_ok "$f")"
  else
    check "$id: proceed branch carries its OFF marker" yes "$(branch_ok "$f" "$id" proceed "$pm")"
  fi
  check "$id: ask branch carries its ON marker" yes "$(branch_ok "$f" "$id" ask "$am")"
done <<'ROWS'
CI-5|DELEGATED|WORKFLOW_CONFIRM_INTENT: {
MOP-8|without `<<WORKFLOW_CONFIRM_OUTLINE>>`|WORKFLOW_CONFIRM_OUTLINE: {
MDP-7|WORKFLOW_MARK_STEP_detail_complete|WORKFLOW_CONFIRM_DETAIL: {
WT-8|no user wait|present the test file content
WCD-6|no user wait|present the file list
UD-5|without waiting|AskUserQuestion
WS-7|surface summary, proceed.|AskUserQuestion
ROWS
case_end

case_begin "cpa3-defines-four-gate-actions" "skills/_shared/confirm-plan.md"
check "CPA-3 proceed = the caller's OFF branch" yes "$(cpa_def_ok "$CPA" proceed "OFF branch")"
check "CPA-3 proceed covers plan stages (CI-5 delegation target)" yes "$(cpa_def_ok "$CPA" proceed "plan stages: print a one-paragraph prose summary")"
check "CPA-3 ask = the caller's ON branch" yes "$(cpa_def_ok "$CPA" ask "ON branch")"
check "CPA-3 present-and-stop ends the turn" yes "$(cpa_def_ok "$CPA" present-and-stop "end the turn")"
check "CPA-3 none takes neither branch" yes "$(cpa_def_ok "$CPA" none "take neither branch")"
case_end

echo "=== mutation probe: the branch assertions can fail (temp copies only) ==="
case_begin "branch-assertion-mutation-probe" "skills/write-tests/SKILL.md"
MUT="$(make_tmp)"; trap 'rm -rf "$MUT"' EXIT
sed -e 's/GATE_ACTION=proceed/GATE_ACTION=TMPSWAP/' -e 's/GATE_ACTION=ask/GATE_ACTION=proceed/' -e 's/GATE_ACTION=TMPSWAP/GATE_ACTION=ask/' "$WT" > "$MUT/wt-swapped.md"
grep -vF '`GATE_ACTION=ask`' "$WT" > "$MUT/wt-no-ask.md"
grep -vF "$CI_DELEGATION" "$CI" > "$MUT/ci-no-delegation.md"
sed -e 's/OFF branch/ON-SWAP branch/' -e 's/ON branch/OFF branch/' -e 's/ON-SWAP branch/ON branch/' "$CPA" > "$MUT/cpa-swapped.md"
check "control: the unmutated copy passes" yes "$(cp "$WT" "$MUT/wt-orig.md"; branch_ok "$MUT/wt-orig.md" WT-8 proceed "no user wait")"
check "swapped branches: proceed marker check fails" no "$(branch_ok "$MUT/wt-swapped.md" WT-8 proceed "no user wait")"
check "swapped branches: ask marker check fails" no "$(branch_ok "$MUT/wt-swapped.md" WT-8 ask "present the test file content")"
check "removed ask branch: ask check fails" no "$(branch_ok "$MUT/wt-no-ask.md" WT-8 ask "present the test file content")"
check "removed CI-5 delegation: delegation check fails" no "$(ci_proceed_ok "$MUT/ci-no-delegation.md")"
check "swapped CPA-3 OFF/ON: proceed definition check fails" no "$(cpa_def_ok "$MUT/cpa-swapped.md" proceed "OFF branch")"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
