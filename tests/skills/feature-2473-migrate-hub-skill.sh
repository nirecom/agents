#!/usr/bin/env bash
# tests/skills/feature-2473-migrate-hub-skill.sh
# Tests: skills/migrate/SKILL.md
# Tags: TL2, skills, migrate, scope:issue-specific
# Issue #2473: /migrate is the only place that branches on bin/migrate-needs. Pins the three steps
# MG-1..MG-3, the all-done path through MG-3, skip exits only in MG-1 (MALFORMED) / MG-2 / On failure,
# the four impacts and the run_tests backstop, the recovery exception's reason and boundary, and the
# three MIGRATE_RESULT lines. settle.sh behavior: tests/skills/feature-2473-migrate-settle.sh.
# TL3 gap: a model actually following the prompt; here the text is checked.
# lang-check: ignore — Japanese literals match real localized output
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

LOCAL_SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/migrate/SKILL.md"

# section <N> — the text of step MG-N: from the line that opens MG-N (a heading or a list item
# starting with it) up to the line that opens the next MG step or the next "## " heading.
SECTION_JS=""
read -r -d '' SECTION_JS <<'JS' || true
const lines = require("fs").readFileSync(process.argv[1], "utf8").split(/\r?\n/);
const open = (l) => { const m = /^\s*(?:#+\s*|[-*]\s+|\d+\.\s+)?\**\s*MG-(\d+)\b/.exec(l); return m ? m[1] : null; };
let on = false; const out = [];
for (const l of lines) {
  const n = open(l);
  if (n !== null) on = n === process.argv[2];
  else if (/^## /.test(l)) on = false;
  if (on) out.push(l);
}
process.stdout.write(out.join("\n"));
JS
section() { node -e "$SECTION_JS" "$(np "$LOCAL_SKILL_MD")" "$1"; }
# heading_section <title> — the text under "## <title>" up to the next "## " heading.
heading_section() { awk -v h="## $1" 'index($0, h) == 1 { on = 1; next } /^## / { on = 0 } on' "$LOCAL_SKILL_MD"; }
has() { printf '%s\n' "$1" | grep -Eqi -- "$2"; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }
SKIP_RE='見送る|skip for this session|skip'

if [ ! -f "$LOCAL_SKILL_MD" ]; then
  for c in MG-steps MG-all-done-path MG-skip-exits MG-impacts MG-recovery-exception MG-result-lines MG-passthrough MG-2-stop-first-failure MG-settled-unpushed MG-1-malformed MG-procedure-step-limit; do
    case_begin "$c" "skills/migrate/SKILL.md"
    fail "$c" "skills/migrate/SKILL.md does not exist"
    case_end
  done
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
  exit 1
fi
BODY="$(cat "$LOCAL_SKILL_MD")"

case_begin "MG-steps" "skills/migrate/SKILL.md"
for n in 1 2 3; do
  check "MG-$n opens a step" '[ -n "$(section "$n")" ]'
done
for n in 4 5 6; do
  check "MG-$n does not open a step" '[ -z "$(section "$n")" ]' "$(section "$n")"
done
check "no MG-4 or later is referenced anywhere" '! has "$BODY" "MG-([4-9]|[1-9][0-9])"' "$(printf '%s\n' "$BODY" | grep -nE 'MG-([4-9]|[1-9][0-9])')"
check "MG-1 calls bin/migrate-needs" 'has "$(section 1)" "bin/migrate-needs"'
check "MG-1 sends a non-zero exit to On failure" 'has "$(section 1)" "non-zero exit[^.]*On failure"' "$(section 1)"
S3="$(section 3)"
check "MG-3 calls skills/migrate/scripts/settle.sh" 'has "$S3" "skills/migrate/scripts/settle\\.sh"' "$S3"
check "MG-3 sends a non-zero exit to On failure" 'has "$S3" "non-zero[^.]*On failure"' "$S3"
ON_FAILURE="$(heading_section "On failure")"
check "On failure is a heading with content" '[ -n "$ON_FAILURE" ]'
check "the On failure heading has no step label" 'grep -Eq "^## On failure[[:space:]]*$" "$LOCAL_SKILL_MD"' "$(grep -n 'On failure' "$LOCAL_SKILL_MD" | head -3)"
case_end

case_begin "MG-all-done-path" "skills/migrate/SKILL.md"
S2="$(section 2)"
S3="$(section 3)"
EMPTY_LINE="$(printf '%s\n' "$S2" | grep -Ei 'NEEDED[^.]*empty')"
check "MG-2 sends NEEDED empty to MG-3" 'has "$EMPTY_LINE" "empty[^.]*MG-3"' "$S2"
check "MG-2 states it asks nothing for NEEDED empty" 'has "$EMPTY_LINE" "ask(ing|s)? nothing|no question|without asking"' "$EMPTY_LINE"
check "MG-2 raises no AskUserQuestion for NEEDED empty" '[ -n "$EMPTY_LINE" ] && ! has "$EMPTY_LINE" "AskUserQuestion"' "$EMPTY_LINE"
check "MG-2 asks only when NEEDED lists a skill" 'has "$S2" "NEEDED[^.]*lists? a skill[^.]*AskUserQuestion"' "$S2"
check "MG-3 raises no AskUserQuestion" '[ -n "$S3" ] && ! has "$S3" "AskUserQuestion"' "$S3"
check "MG-3 prints the MIGRATE_RESULT line of settle.sh as is" 'has "$S3" "settle\\.sh" && has "$S3" "MIGRATE_RESULT[^.]*(as is|as-is|verbatim)"' "$S3"
case_end

case_begin "MG-skip-exits" "skills/migrate/SKILL.md"
S2="$(section 2)"
ON_FAILURE="$(heading_section "On failure")"
check "MG-2 offers the session skip through AskUserQuestion" 'has "$S2" "AskUserQuestion" && has "$S2" "$SKIP_RE"' "$S2"
check "MG-2 emits MIGRATE_RESULT=skipped" 'has "$S2" "MIGRATE_RESULT=skipped"' "$S2"
check "On failure offers the session skip through AskUserQuestion" 'has "$ON_FAILURE" "AskUserQuestion" && has "$ON_FAILURE" "$SKIP_RE"' "$ON_FAILURE"
check "On failure emits MIGRATE_RESULT=skipped" 'has "$ON_FAILURE" "MIGRATE_RESULT=skipped"' "$ON_FAILURE"
check "On failure offers stop with MIGRATE_RESULT=failed" 'has "$ON_FAILURE" "stop" && has "$ON_FAILURE" "MIGRATE_RESULT=failed"' "$ON_FAILURE"
check "MG-3 offers no skip choice" '[ -n "$(section 3)" ] && ! has "$(section 3)" "AskUserQuestion"' "$(section 3)"
RULES="$(heading_section "Rules")"
check "Rules limits skip exits to MG-1 (MALFORMED=1), MG-2 and On failure" 'has "$RULES" "skip exits[^.]*MG-1[^.]*MALFORMED=1[^.]*MG-2[^.]*On failure"' "$RULES"
case_end

case_begin "MG-impacts" "skills/migrate/SKILL.md"
S2="$(section 2)"
check "MG-2 names the label step in clarify_intent" 'has "$S2" "clarify_intent" && has "$S2" "label"' "$S2"
check "MG-2 names the WIP record" 'has "$S2" "WIP"'
check "MG-2 names the Projects v2 registration" 'has "$S2" "Projects v2"'
check "MG-2 names the session-close board update" 'has "$S2" "session.close" && has "$S2" "board"'
check "MG-2 names the run_tests backstop" 'has "$S2" "run_tests"'
check "On failure repeats the impacts (in full or by pointing at MG-2)" 'has "$(heading_section "On failure")" "MG-2|Projects v2"'
case_end

# The recovery behavior itself is pinned in tests/skills/feature-2473-migrate-settle.sh.
case_begin "MG-recovery-exception" "skills/migrate/SKILL.md"
RECOVERY_LINE="$(heading_section "Rules" | grep -Ei 'recovery[^.]*exception|exception[^.]*recovery')"
check "Rules names the commit recovery exception" 'has "$RECOVERY_LINE" "commit recovery"' "$(heading_section "Rules")"
check "the exception names settle.sh" 'has "$RECOVERY_LINE" "settle\\.sh"' "$RECOVERY_LINE"
check "the exception states its reason (every needs.js already says done)" 'has "$RECOVERY_LINE" "needs\\.js[^.]*(done)|every[^.]*needs\\.js"' "$RECOVERY_LINE"
check "the exception states the boundary: stages .agents.json only" 'has "$RECOVERY_LINE" "stages .?\\.agents\\.json.? only"' "$RECOVERY_LINE"
check "the hub no longer inlines the recovery commit in MG-3" '! has "$(section 3)" "commit-migration-artifacts"' "$(section 3)"
case_end

case_begin "MG-result-lines" "skills/migrate/SKILL.md"
results="$(printf '%s\n' "$BODY" | grep -Eo 'MIGRATE_RESULT=[a-z]+' | sort -u | tr '\n' ' ')"
assert_eq "$results" "MIGRATE_RESULT=failed MIGRATE_RESULT=ok MIGRATE_RESULT=skipped " # exactly three result values
RULES="$(heading_section "Rules")"
check "Rules requires exactly one MIGRATE_RESULT line per run" 'has "$RULES" "exactly one .?MIGRATE_RESULT.? line per run"' "$RULES"
case_end

case_begin "MG-passthrough" "skills/migrate/SKILL.md"
INPUTS="$(printf '%s\n' "$BODY" | awk '/^## Inputs/{on=1;next} /^## /{on=0} on')"
check "Inputs passes ROOT and HOST to each sub-skill" 'has "$INPUTS" "Pass .?ROOT.? and the .?HOST.? from MG-1 to each sub-skill"' "$INPUTS"
for opt in --no-push --dry-run; do
  check "Inputs forwards $opt verbatim to every sub-skill" 'has "$INPUTS" "forwarded verbatim to every sub-skill" && has "$INPUTS" "$opt"' "$INPUTS"
done
check "MG-1 keeps HOST from bin/migrate-needs" 'has "$(section 1)" "HOST"'
S2="$(section 2)"
check "MG-2 invokes each NEEDED skill with ROOT / HOST / options" 'has "$S2" "ROOT.{0,8}HOST.{0,8}options"' "$S2"
S3="$(section 3)"
for opt in --no-push --dry-run; do
  check "MG-3 passes $opt to settle.sh only when the hub was given it" 'has "$S3" "settle\\.sh[^.]*\\(plus [^)]*$opt[^)]* when given\\)"' "$S3"
done
for sub in /migrate-tracker /migrate-issues /migrate-tests; do
  check "the hub names $sub" 'has "$BODY" "$sub([^-a-z]|$)"'
done
case_end

case_begin "MG-2-stop-first-failure" "skills/migrate/SKILL.md"
S2="$(section 2)"
ON_FAILURE="$(heading_section "On failure")"
check "MG-2 stops at the first failure" 'has "$S2" "stop at the first failure"' "$S2"
check "MG-2 routes the failure to On failure" 'has "$S2" "first failure[^.]*On failure"' "$S2"
check "MG-2 reaches MG-3 only after the run" 'has "$S2" "Then go to MG-3"' "$S2"
check "On failure shows the failing sub-skill output" 'has "$ON_FAILURE" "failing output.*sub-skill"' "$ON_FAILURE"
check "On failure shows the failing settle.sh output" 'has "$ON_FAILURE" "failing output.*settle\\.sh"' "$ON_FAILURE"
case_end

# Completion = UNCOMMITTED=0 and (UNPUSHED=0 or --no-push); the decision itself is settle.sh's,
# pinned by behavior in tests/skills/feature-2473-migrate-settle.sh.
case_begin "MG-settled-unpushed" "skills/migrate/SKILL.md"
S1="$(section 1)"
check "MG-1 keeps UNPUSHED from bin/migrate-needs" 'has "$S1" "UNPUSHED"' "$S1"
check "MG-1 defines settled as UNCOMMITTED=0 and UNPUSHED=0 or --no-push" 'has "$S1" "UNCOMMITTED=0.*UNPUSHED=0.*--no-push"' "$S1"
case_end

# A malformed .agents.json is repaired once here, not per write: MG-1 asks before MG-2 whether to
# reset it (original kept in .agents.json.malformed) or skip the session.
case_begin "MG-1-malformed" "skills/migrate/SKILL.md"
S1="$(section 1)"
check "MG-1 keeps MALFORMED from bin/migrate-needs" 'has "$S1" "MALFORMED"' "$S1"
check "MG-1 branches on MALFORMED=1" 'has "$S1" "MALFORMED=1"' "$S1"
check "MG-1 asks through AskUserQuestion when MALFORMED=1" 'has "$S1" "MALFORMED=1[^.]*AskUserQuestion|AskUserQuestion[^.]*MALFORMED=1"' "$S1"
check "MG-1 asks before MG-2" 'has "$S1" "before MG-2"' "$S1"
check "MG-1 resets through bin/repo-settings --root <ROOT> --reset-malformed" 'has "$S1" "bin/repo-settings[^.]*--root[^.]*--reset-malformed"' "$S1"
check "MG-1 names the .agents.json.malformed backup" 'has "$S1" "\\.agents\\.json\\.malformed"' "$S1"
check "MG-1 re-runs MG-1 after the reset" 'has "$S1" "--reset-malformed[^.]*re-?run|re-?run MG-1"' "$S1"
check "MG-1 offers Skip for this session with MIGRATE_RESULT=skipped" 'has "$S1" "skip for this session" && has "$S1" "MIGRATE_RESULT=skipped"' "$S1"
check "MG-1 never resets under --dry-run (reports that it would)" 'has "$S1" "--dry-run[^.]*(never|not|without)[^.]*reset|(never|not)[^.]*reset[^.]*--dry-run"' "$S1"
check "MG-1 reports the reset it would make under --dry-run" 'has "$S1" "--dry-run[^.]*would|would[^.]*--dry-run"' "$S1"
check "the hub names --replace-malformed nowhere" '! has "$BODY" "--replace-malformed"'
case_end

# rules/prompt.md 1.3 caps an inlined procedure at 3 steps; a re-inline is caught here as well as
# by the commit gate.
case_begin "MG-procedure-step-limit" "skills/migrate/SKILL.md"
PROCEDURE_LABELS="$(heading_section "Procedure" | grep -Eo 'MG-[0-9]+[a-z]?' | sort -u | grep -c '' || true)"
check "Procedure holds 1 to 3 distinct MG-N labels" '[ "$PROCEDURE_LABELS" -ge 1 ] && [ "$PROCEDURE_LABELS" -le 3 ]' "got $PROCEDURE_LABELS"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
