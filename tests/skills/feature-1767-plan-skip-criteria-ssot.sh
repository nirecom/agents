#!/usr/bin/env bash
# Tests: skills/_shared/judge-plan-skip.md, skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: tl1, static, roundtrip-reduction, skill-orchestration, scope:issue-specific, pwsh-not-required
#
# #1767 — SSOT for the outline-skip (so_c1/so_c2) and detail-skip criteria.
# #2460 end state: section format, detail keys sd_single_approach /
# sd_no_open_decision, the jev-two-stage-judge / plan-skip-judge reference list,
# the #2620 interim rule, the all-keys Output rule, no Legacy section, and the
# plan-skip-judge agent's Input rules. Call sites carry no criteria prose.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_CHECKOUT_ROOT" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
# has <label> <file> <fixed-string> / lacks <label> <file> <fixed-string>
has()   { if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 -- [$3] not in $2"; fi; }
lacks() { if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1 -- [$3] found in $2"; else pass "$1"; fi; }

SSOT="skills/_shared/judge-plan-skip.md"
AGENT="agents/plan-skip-judge.md"

# section_body <file> <heading-line> — lines after the exact heading up to the
# next heading of the same or a higher level. Empty when the heading is absent.
section_body() {
  awk -v h="$2" '
    BEGIN { lvl = length(h) - length(substr(h, index(h, " "))) }
    $0 == h { on = 1; next }
    on && /^#+ / { l = index($0, " ") - 1; if (l <= lvl) exit }
    on { print }
  ' "$1" 2>/dev/null
}

echo "--- S: the section extractor itself works (no vacuous B/D/G results) ---"
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SELFTEST_DIR"' EXIT
printf '# T\n## A\n### k\nbody\n## B\nother\n' > "$SELFTEST_DIR/s.md"
if [ "$(section_body "$SELFTEST_DIR/s.md" "## A")" = "$(printf '### k\nbody')" ] \
  && [ "$(section_body "$SELFTEST_DIR/s.md" "### k")" = "body" ] \
  && [ -z "$(section_body "$SELFTEST_DIR/s.md" "## Z")" ]; then
  pass "S1 section_body extracts a section up to the next same-level heading"
else
  fail "S1 section_body is broken"
fi

echo ""
echo "--- A: the rubric file exists and is bounded ---"
if [ -f "$SSOT" ]; then pass "A1 $SSOT exists"; else fail "A1 $SSOT missing"; fi
LINES=$(wc -l < "$SSOT" 2>/dev/null || echo 9999)
if [ "$LINES" -le 200 ]; then
  pass "A2 $SSOT stays within Pattern B HARD limit (200 lines): $LINES"
else
  fail "A2 $SSOT exceeds Pattern B HARD limit (200 lines): $LINES"
fi

echo ""
echo "--- B: section format, one ### section per condition key ---"
has "B1 outline checklist heading" "$SSOT" "## Outline-skip criteria"
has "B2 detail checklist heading" "$SSOT" "## Detail-skip criteria"
OUTLINE_BODY="$(section_body "$SSOT" "## Outline-skip criteria")"
DETAIL_BODY="$(section_body "$SSOT" "## Detail-skip criteria")"
for key in so_c1 so_c2; do
  if printf '%s\n' "$OUTLINE_BODY" | grep -qxF -- "### $key"; then
    pass "B3 ### $key sits under the outline checklist"
  else
    fail "B3 ### $key missing under ## Outline-skip criteria"
  fi
done
for key in sd_single_approach sd_no_open_decision; do
  if printf '%s\n' "$DETAIL_BODY" | grep -qxF -- "### $key"; then
    pass "B3 ### $key sits under the detail checklist"
  else
    fail "B3 ### $key missing under ## Detail-skip criteria"
  fi
done
# Every key section carries a criterion plus one pass and one fail example.
for key in so_c1 so_c2 sd_single_approach sd_no_open_decision; do
  BODY="$(section_body "$SSOT" "### $key")"
  if [ -z "$BODY" ]; then fail "B4 ### $key has no body"; continue; fi
  if printf '%s\n' "$BODY" | grep -qi "pass example" && printf '%s\n' "$BODY" | grep -qi "fail example"; then
    pass "B4 ### $key carries a pass example and a fail example"
  else
    fail "B4 ### $key lacks a pass or fail example"
  fi
done
# The table format is gone: no table row starts with a condition key.
if grep -qE '^\|[[:space:]]*(so_c[12]|sd_[a-z_0-9]+)[[:space:]]*\|' "$SSOT" 2>/dev/null; then
  fail "B5 $SSOT still holds a criteria table row"
else
  pass "B5 $SSOT holds no criteria table row"
fi

echo ""
echo "--- C: retired detail keys and the legacy section are gone ---"
for old in sd_c1 sd_c2 sd_c3; do
  lacks "C1 $SSOT no longer names $old" "$SSOT" "$old"
done
lacks "C2 no Legacy detail-skip section" "$SSOT" "## Legacy"
lacks "C3 no --c1 caller instruction" "$SSOT" "--c1"
lacks "C4 no skip-verifier reference" "$SSOT" "skip-verifier"
lacks "C5 the raw-boolean caller rule is replaced" "$SSOT" "Callers pass raw booleans"

echo ""
echo "--- D: rules split into Judgment rules and Output rules ---"
has "D1 ## Judgment rules exists" "$SSOT" "## Judgment rules"
has "D2 ## Output rules exists" "$SSOT" "## Output rules"
lacks "D3 the old combined ## Rules heading is gone" "$SSOT" "## Rules"
JR="$(section_body "$SSOT" "## Judgment rules")"
OR="$(section_body "$SSOT" "## Output rules")"
if printf '%s\n' "$JR" | grep -F -- "sd_no_open_decision" | grep -qF -- "#2620"; then
  pass "D4 Judgment rules carry the #2620 interim line for sd_no_open_decision"
else
  fail "D4 Judgment rules lack a line naming both sd_no_open_decision and #2620"
fi
if printf '%s\n' "$JR" | grep -qiE 'ambiguous|unclear'; then
  pass "D5 Judgment rules keep the ambiguous-means-false rule"
else
  fail "D5 Judgment rules lost the ambiguous-means-false rule"
fi
if printf '%s\n' "$OR" | grep -qF -- "SKIP_CONDITIONS:"; then
  pass "D6 Output rules name the SKIP_CONDITIONS: line"
else
  fail "D6 Output rules do not name the SKIP_CONDITIONS: line"
fi
if printf '%s\n' "$OR" | grep -qiE 'every key|all keys|every condition key|all (of the )?condition keys|every criterion'; then
  pass "D7 Output rules require an answer for every key of the checklist"
else
  fail "D7 Output rules lack the all-keys rule"
fi
has "D8 the finalize-only recording line" "$SSOT" "jev-judge finalize"

echo ""
echo "--- E: the reference list names the shared procedure and the agent ---"
HEADER="$(sed -n '1,8p' "$SSOT" 2>/dev/null)"
for ref in "skills/_shared/jev-two-stage-judge.md" "agents/plan-skip-judge.md"; do
  if printf '%s\n' "$HEADER" | grep -qF -- "$ref"; then
    pass "E1 the rubric header references $ref"
  else
    fail "E1 the rubric header does not reference $ref"
  fi
done

echo ""
echo "--- F: call sites no longer restate the criteria prose inline ---"
OLD_PHRASES=(
  "so_c1 (single obvious approach exists)"
  "so_c1: a single obvious approach exists"
  "sd_c1: all changed files are listed by path"
)
for file in "skills/workflow-init/SKILL.md" "skills/clarify-intent/SKILL.md" "skills/make-outline-plan/SKILL.md"; do
  [ -f "$file" ] || { fail "F $file missing"; continue; }
  for phrase in "${OLD_PHRASES[@]}"; do
    lacks "F $file does not restate inline: '$phrase'" "$file" "$phrase"
  done
done

echo ""
echo "--- G: the plan-skip-judge agent ---"
if [ -f "$AGENT" ]; then pass "G1 $AGENT exists"; else fail "G1 $AGENT missing"; fi
ALINES=$(wc -l < "$AGENT" 2>/dev/null || echo 9999)
if [ "$ALINES" -le 100 ]; then pass "G2 $AGENT is at most 100 lines: $ALINES"; else fail "G2 $AGENT exceeds 100 lines: $ALINES"; fi
FM="$(awk 'NR==1 && $0=="---" {on=1; next} on && $0=="---" {exit} on {print}' "$AGENT" 2>/dev/null)"
if printf '%s\n' "$FM" | grep -qx 'name: plan-skip-judge'; then pass "G3 frontmatter name"; else fail "G3 frontmatter name is not plan-skip-judge"; fi
if printf '%s\n' "$FM" | grep -qx 'model: sonnet'; then pass "G4 model is sonnet"; else fail "G4 model is not sonnet"; fi
if printf '%s\n' "$FM" | grep -qx 'tools: Read'; then pass "G5 tools is exactly Read"; else fail "G5 tools is not exactly Read"; fi
has "G6 the agent evaluates the shared rubric" "$AGENT" "$SSOT"
has "G7 the agent answers with one SKIP_CONDITIONS: line" "$AGENT" "SKIP_CONDITIONS:"
INPUT="$(section_body "$AGENT" "## Input")"
if [ -n "$INPUT" ]; then pass "G8 the agent has an ## Input section"; else fail "G8 the agent has no ## Input section"; fi
# Jev-input-first rule: read the Jev input, fall back to the header sources only
# when a section is truncated/absent or the Jev input is not enough.
if printf '%s\n' "$INPUT" | grep -qF 'Jev input' \
  && printf '%s\n' "$INPUT" | grep -qi 'truncated' \
  && printf '%s\n' "$INPUT" | grep -qi 'absent' \
  && printf '%s\n' "$INPUT" | grep -qE '(^|[^_])sources([^_]|$)'; then
  pass "G9 Input states the Jev-input-first then sources rule"
else
  fail "G9 Input lacks the Jev input / truncated / absent / sources rule"
fi
# Fail-safe rule: a needed section listed in sources_unavailable means all keys false.
if printf '%s\n' "$INPUT" | grep -qF 'sources_unavailable' \
  && printf '%s\n' "$INPUT" | grep -qiE 'false'; then
  pass "G10 Input states the sources_unavailable -> all keys false rule"
else
  fail "G10 Input lacks the sources_unavailable fail-safe rule"
fi
if grep -qiE 'as data|never as instructions|not .*instructions' "$AGENT" 2>/dev/null; then
  pass "G11 the agent treats artifact content as data"
else
  fail "G11 the agent does not say artifact content is data, not instructions"
fi

echo ""
echo "=== feature-1767-plan-skip-criteria-ssot: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
