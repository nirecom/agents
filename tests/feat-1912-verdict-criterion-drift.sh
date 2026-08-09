#!/usr/bin/env bash
# tests/feat-1912-verdict-criterion-drift.sh
# Tests: skills/_shared/issue-verdict-cascade.md, bin/github-issues/lib/validate-review-verdict.js, agents/issue-create-survey-worker.md, bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, cascade, same-fix, ssot, drift, prompt-assembly, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether a real `codex exec` and a real survey subagent actually DECIDE by the
#   embedded cascade. A prompt that carries the table proves reach, not obedience;
#   only a real-model run could show drift in the answer itself, and #1912 accepted
#   that residual risk explicitly rather than building a model-dependent test.
# - Whether the DEPLOYED copy under $HOME/.claude matches the worktree copy. This file
#   reads the worktree.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# `same_fix` lives in three places that must agree: the cascade SSOT table, the
# validator's map, and the assembled reviewer prompt. This file pins the agreement.
# The comparison is a SUBSET one: `bulk-sub-of` is in the JS map (artifact grammar)
# but must NOT be in the cascade table (review grammar), so equality would never hold.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

CASCADE="$AGENTS_DIR/skills/_shared/issue-verdict-cascade.md"
VALIDATOR="$AGENTS_DIR/bin/github-issues/lib/validate-review-verdict.js"
WORKER_MD="$AGENTS_DIR/agents/issue-create-survey-worker.md"
CODEX_SH="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- section scoping (CPR-SC) ---------------------------------------------------------
# Doc-contract cases read ONE cascade section, not the whole file: e.g. "sub-of ... meta
# parent" also appears in the IC-C2 heading, which would satisfy M6 while stating nothing.
# Each section gets a line-oriented copy (for rows/standalone directives) and a flattened
# copy (for sentences the file wraps across lines).
md_section() {  # <file> <heading-regex> → the body of that `## ` section, headings excluded
    [ -f "$1" ] || return 0
    awk -v re="$2" '
      /^##[[:space:]]/ { inb = ($0 ~ re) ? 1 : 0; next }
      inb { print }' "$1"
}

ICC1="$WORK/icc1.txt"; ICC1_FLAT="$WORK/icc1-flat.txt"
SAMEFIX_BLOCK="$WORK/samefix.txt"; SAMEFIX_FLAT="$WORK/samefix-flat.txt"
CASCADE_FLAT="$WORK/cascade-flat.txt"

md_section "$CASCADE" '^##[[:space:]]+IC-C1'   > "$ICC1"          2>/dev/null || : > "$ICC1"
md_section "$CASCADE" '^##[[:space:]]+same_fix' > "$SAMEFIX_BLOCK" 2>/dev/null || : > "$SAMEFIX_BLOCK"
tr '\n' ' ' < "$ICC1"          > "$ICC1_FLAT"    2>/dev/null || : > "$ICC1_FLAT"
tr '\n' ' ' < "$SAMEFIX_BLOCK" > "$SAMEFIX_FLAT" 2>/dev/null || : > "$SAMEFIX_FLAT"
if [ -f "$CASCADE" ]; then tr '\n' ' ' < "$CASCADE" > "$CASCADE_FLAT"; else : > "$CASCADE_FLAT"; fi

# table_rows <file> → sorted `verdict=bool` lines for every 2-column markdown row.
# Backticks/whitespace stripped so either spelling parses; rows whose second column is
# not a bare boolean (separators, prose tables) are skipped, not mis-parsed.
table_rows() {
    [ -f "$1" ] || return 0
    awk -F'|' '
      /^[[:space:]]*\|/ && NF >= 3 {
        v = $2; b = $3;
        gsub(/[ \t`]/, "", v); gsub(/[ \t`]/, "", b);
        if (b == "true" || b == "false") print v "=" b;
      }' "$1" | LC_ALL=C sort
}

echo "=== P: the cascade table and SAME_FIX_BY_VERDICT agree (5-verdict subset) ==="

CASCADE_ROWS="$WORK/cascade-rows.txt"
JS_ROWS="$WORK/js-rows.txt"
table_rows "$CASCADE" > "$CASCADE_ROWS"

: > "$JS_ROWS"
JS_HAS_BULK=no
if [ -f "$VALIDATOR" ]; then
    "$RWT" 15 node -e '
const m = require(process.argv[1]);
const t = m.SAME_FIX_BY_VERDICT;
if (!t || typeof t !== "object") process.exit(0);
// Restricted to the REVIEW grammar (m.VERDICTS) — the same list the reviewer is
// allowed to answer with, so the subset boundary is taken from the code, not retyped.
for (const v of m.VERDICTS.slice().sort()) {
  if (Object.prototype.hasOwnProperty.call(t, v)) console.log(v + "=" + JSON.stringify(t[v]));
}' "$(node_path "$VALIDATOR")" 2>/dev/null | LC_ALL=C sort > "$JS_ROWS" || true
    if "$RWT" 15 node -e '
const t = require(process.argv[1]).SAME_FIX_BY_VERDICT;
process.exit(t && Object.prototype.hasOwnProperty.call(t, "bulk-sub-of") ? 0 : 1);' \
        "$(node_path "$VALIDATOR")" >/dev/null 2>&1; then
        JS_HAS_BULK=yes
    fi
fi

# `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback would append a
# SECOND zero and every later [ -eq ] would die on "0\n0".
count_lines() { local n; n=$(grep -c . "$1" 2>/dev/null) || true; printf '%s' "${n:-0}"; }

CROWS=$(count_lines "$CASCADE_ROWS")
JROWS=$(count_lines "$JS_ROWS")

# P1/P2 keep P3 non-vacuous: two empty lists would compare "equal".
if [ "$CROWS" -eq 5 ]; then
    pass "P1-cascade-table-has-five-rows"
else
    fail "P1-cascade-table-has-five-rows" "the cascade must carry a fixed 2-column same_fix table for the 5 review verdicts (parsed rows: $CROWS)"
fi

if [ "$JROWS" -eq 5 ]; then
    pass "P2-js-map-covers-five-review-verdicts"
else
    fail "P2-js-map-covers-five-review-verdicts" "SAME_FIX_BY_VERDICT must define every verdict in VERDICTS (parsed rows: $JROWS)"
fi

if [ "$CROWS" -eq 5 ] && [ "$JROWS" -eq 5 ] && diff -q "$CASCADE_ROWS" "$JS_ROWS" >/dev/null 2>&1; then
    pass "P3-cascade-table-matches-js-map"
else
    fail "P3-cascade-table-matches-js-map" "cascade=[$(tr '\n' ' ' < "$CASCADE_ROWS")] js=[$(tr '\n' ' ' < "$JS_ROWS")]"
fi

# The asymmetry is pinned in both directions: absent from the doc table, present in the
# map. One-sided, an edit could "complete" the table with a verdict the reviewer may not
# answer with.
if [ "$CROWS" -gt 0 ] && ! grep -q '^bulk-sub-of=' "$CASCADE_ROWS"; then
    pass "P4-cascade-table-omits-bulk-sub-of"
else
    fail "P4-cascade-table-omits-bulk-sub-of" "bulk-sub-of is outside the review grammar and must not appear in the cascade table (rows: $(tr '\n' ' ' < "$CASCADE_ROWS"))"
fi

if [ "$JS_HAS_BULK" = "yes" ]; then
    pass "P5-js-map-keeps-bulk-sub-of"
else
    fail "P5-js-map-keeps-bulk-sub-of" "the artifact grammar admits bulk-sub-of, so the map must define it (got: absent)"
fi

echo ""
echo "=== M: both parent-attaching verdicts are false in the cascade table (standalone) ==="

# Independent of the awk parser above: if the table shape stops parsing, P3 degrades to
# a parse complaint while M1 still reports the value #1912 reverses.
if [ ! -f "$CASCADE" ]; then
    fail "M1-make-parent-row-is-false" "cascade SSOT not found at $CASCADE"
elif grep -qE '^[[:space:]]*\|[^|]*make-parent[^|]*\|[[:space:]]*`?false`?[[:space:]]*\|' "$CASCADE"; then
    pass "M1-make-parent-row-is-false"
else
    fail "M1-make-parent-row-is-false" "the cascade table must state make-parent = false (grouped issues each keep their own fix)"
fi

# The counter-assertion: a table row saying `true` is the exact drift this PR reverses.
if [ -f "$CASCADE" ] && grep -qE '^[[:space:]]*\|[^|]*make-parent[^|]*\|[[:space:]]*`?true`?[[:space:]]*\|' "$CASCADE"; then
    fail "M2-make-parent-row-not-true" "the cascade table says make-parent = true — the pre-#1912 value"
else
    pass "M2-make-parent-row-not-true"
fi

# A value with no stated reason is a value the next editor will 'correct'.
# Flattened before matching because the rationale wraps across lines; scoped to the
# `same_fix` section so the reason must sit with the table it explains.
if grep -qiE 'make-parent[^.]*(own fix|its own|each [^.]*fix)|(own fix|each keeps)[^.]*make-parent' "$SAMEFIX_FLAT"; then
    pass "M3-make-parent-false-has-a-stated-reason"
else
    fail "M3-make-parent-false-has-a-stated-reason" "the text after the table must say why make-parent is false (children each carry their own fix)"
fi

# --- sub-of: the value #1912 reverses on the parent-ATTACHING side ----------------------
# CPR-ORTH: sub-of and make-parent both name a meta parent, so both get the pin.
# Standalone for the same reason M1/M2 are (parser-independent).
if [ ! -f "$CASCADE" ]; then
    fail "M4-sub-of-row-is-false" "cascade SSOT not found at $CASCADE"
elif grep -qE '^[[:space:]]*\|[^|]*`?sub-of`?[^|]*\|[[:space:]]*`?false`?[[:space:]]*\|' "$CASCADE"; then
    pass "M4-sub-of-row-is-false"
else
    fail "M4-sub-of-row-is-false" "the cascade table must state sub-of = false (attaching to a meta parent resolves nothing)"
fi

# The counter-assertion: `true` is the pre-#1912 value this PR reverses.
if [ -f "$CASCADE" ] && grep -qE '^[[:space:]]*\|[^|]*`?sub-of`?[^|]*\|[[:space:]]*`?true`?[[:space:]]*\|' "$CASCADE"; then
    fail "M5-sub-of-row-not-true" "the cascade table says sub-of = true — the pre-#1912 value"
else
    pass "M5-sub-of-row-not-true"
fi

# The two `false` rows must share ONE stated reason: the issue a parent-attaching verdict
# names is a meta parent, never implemented against.
# Scoped to `same_fix` and load-bearing: whole-file, the IC-C2 heading "sub-of (attach to
# an existing meta parent)" would satisfy this while explaining nothing. Collective and
# per-verdict phrasings both pass, but the section must also NAME sub-of.
if grep -qiE '(sub-of|parent-attaching)[^.]*(meta parent|never implemented|container)|(meta parent|never implemented|container)[^.]*(sub-of|parent-attaching)' "$SAMEFIX_FLAT" \
   && grep -qF 'sub-of' "$SAMEFIX_FLAT"; then
    pass "M6-sub-of-false-has-a-stated-reason"
else
    fail "M6-sub-of-false-has-a-stated-reason" "the same_fix section must say why sub-of is false (it attaches to a meta parent, which is never implemented against); section: $(cat "$SAMEFIX_FLAT")"
fi

echo ""
echo "=== N: symptom similarity alone does not justify reopen ==="

# IC-C1's old wording read 'same root cause OR observed symptom'; the OR let a symptom
# match carry a reopen. The replacement must forbid it in the negative, on its own line.
# All three cases read the IC-C1 BLOCK, not the file: a prohibition parked in a later
# section is one the grader deciding IC-C1 has already walked past.
if [ ! -s "$ICC1" ]; then
    fail "N1-negative-directive-present" "no '## IC-C1' section found in $CASCADE"
elif grep -qiE '^[^|]*(must not|never|do not|don.t)[^|]*symptom' "$ICC1" \
     || grep -qiE '^[^|]*symptom[^|]*(must not|never|do not|don.t)' "$ICC1"; then
    pass "N1-negative-directive-present"
else
    fail "N1-negative-directive-present" "IC-C1 must forbid, in the negative, deciding reopen on symptom similarity alone"
fi

# The directive is worthless if it is not about reopen. Flattened: the sentence wraps.
if [ -s "$ICC1" ] && grep -qiE '(reopen[^|]*symptom|symptom[^|]*reopen)' "$ICC1_FLAT"; then
    pass "N2-directive-names-reopen"
else
    fail "N2-directive-names-reopen" "the symptom directive must name the verdict it constrains (reopen), inside the IC-C1 block"
fi

# Strictening, not loosening: the existing protection against treating surface wording
# differences as non-match must survive the rewrite.
if [ -s "$ICC1" ] && grep -qiE 'surface framing|wording' "$ICC1"; then
    pass "N3-surface-wording-protection-retained"
else
    fail "N3-surface-wording-protection-retained" "IC-C1 must keep the 'surface framing / wording differences are not grounds for non-match' directive"
fi

echo ""
echo "=== O: IC-C1 states the same-fix criterion POSITIVELY, in its own block ==="

# Separate from N: delete the positive rule and keep the negative, and every N case still
# passes while the cascade has lost its criterion. Pinned INSIDE the IC-C1 block because
# the same wording also appears in the `same_fix` section (a lookup, not a decision).
# $ICC1_FLAT is used where the criterion wraps across lines.
if [ -s "$ICC1" ]; then
    pass "O1-icc1-block-is-extractable"
else
    fail "O1-icc1-block-is-extractable" "no '## IC-C1' section found in $CASCADE — every case below reads that block"
fi

# The criterion: ONE fix, BOTH items, AT THE SAME TIME — asserted part by part so the
# failure names the missing one ("one fix" alone also matches "one fix per issue").
if grep -qiE 'one fix' "$ICC1"; then
    pass "O2-icc1-says-one-fix"
else
    fail "O2-icc1-says-one-fix" "IC-C1 must state the criterion in terms of a single fix; block: $(tr '\n' ' ' < "$ICC1")"
fi
if grep -qiE 'one fix[^.]*(this proposal|the proposal)[^.]*candidate' "$ICC1_FLAT"; then
    pass "O3-icc1-names-both-sides-of-the-fix"
else
    fail "O3-icc1-names-both-sides-of-the-fix" "the criterion must name what the one fix has to resolve: the proposal AND the candidate"
fi
if grep -qiE 'at the same time|simultaneous' "$ICC1_FLAT"; then
    pass "O4-icc1-requires-simultaneity"
else
    fail "O4-icc1-requires-simultaneity" "'one fix resolves both' without 'at the same time' admits two sequential fixes, which is exactly the case #1912 excludes"
fi
# The criterion must be operative — an instruction to decide, not a description.
if grep -qiE '(decide|choose|answer)[^.]*reopen|reopen[^.]*(decide|choose)' "$ICC1_FLAT"; then
    pass "O5-icc1-criterion-drives-the-reopen-decision"
else
    fail "O5-icc1-criterion-drives-the-reopen-decision" "the IC-C1 block must instruct the grader to DECIDE reopen when the criterion holds"
fi
# One candidate is enough — otherwise "the proposal and the candidates" reads as
# requiring the whole set to match.
if grep -qiE 'even one candidate|any candidate|for one candidate' "$ICC1_FLAT"; then
    pass "O6-icc1-one-matching-candidate-suffices"
else
    fail "O6-icc1-one-matching-candidate-suffices" "IC-C1 must say a single matching candidate is enough to decide reopen"
fi

# The retired cause-OR-symptom disjunction must be gone. Restricted to the IC-C1 block:
# "symptom" still legitimately appears there in the negative sentence N asserts.
if grep -qiE '(root cause|underlying cause)[^.]*\bor\b[^.]*symptom|symptom[^.]*\bor\b[^.]*(root cause|underlying cause)' "$ICC1_FLAT"; then
    fail "O7-retired-cause-or-symptom-disjunction-absent" "IC-C1 still offers root cause OR symptom as alternatives — this is the pre-#1912 criterion #1912 replaced"
else
    pass "O7-retired-cause-or-symptom-disjunction-absent"
fi

# Both places that phrase the criterion must phrase it the same way, or graders decide
# on different grounds depending on which they read.
if [ -s "$SAMEFIX_BLOCK" ] && grep -qiE 'one[[:space:]]*fix' "$SAMEFIX_BLOCK" \
   && grep -qiE 'IC-C1' "$SAMEFIX_BLOCK"; then
    pass "O8-same-fix-section-defers-to-the-icc1-criterion"
else
    fail "O8-same-fix-section-defers-to-the-icc1-criterion" "the same_fix section must state that it answers the IC-C1 question, so the two definitions cannot drift apart"
fi

echo ""
echo "=== S: both graders reference the SSOT, neither duplicates the table ==="

# S2b–S2f assert what the worker's ONE numbered cascade step says, so they read only that
# step — the same phrases elsewhere in the file would satisfy a whole-file grep while the
# executed step said neither. The block is self-locating (SSOT line → next numbered step),
# so renumbering cannot silently empty it.
WORKER_STEP="$WORK/worker-cascade-step.txt"
: > "$WORKER_STEP"
if [ -f "$WORKER_MD" ]; then
    awk '/issue-verdict-cascade\.md/ { inb = 1 }
         inb && /^[0-9]+\./ && seen { exit }
         inb { seen = 1; print }' "$WORKER_MD" > "$WORKER_STEP" 2>/dev/null || true
fi

if [ -s "$WORKER_STEP" ] && grep -qF 'issue-verdict-cascade.md' "$WORKER_STEP"; then
    pass "S1-worker-references-cascade-file"
else
    fail "S1-worker-references-cascade-file" "the survey worker must point at the cascade SSOT by path, from the procedure step that decides the verdict"
fi

if [ -f "$WORKER_MD" ] && grep -qF 'same_fix' "$WORKER_MD"; then
    pass "S2-worker-mentions-same-fix"
else
    fail "S2-worker-mentions-same-fix" "the survey worker emits same_fix, so it must name the field"
fi

# S4/S5 prove the worker does not COPY the cascade; S2b–S2f pin the instructions that
# make the pointer usable. Both halves are needed — a worker that copies nothing and says
# nothing about how to use the file still passes S1/S2.
if [ -s "$WORKER_STEP" ] && grep -qE 'IC-C1,[[:space:]]*IC-C2,[[:space:]]*IC-C3,[[:space:]]*IC-C4' "$WORKER_STEP"; then
    pass "S2b-worker-states-the-cascade-order"
else
    fail "S2b-worker-states-the-cascade-order" "the worker must name the evaluation order IC-C1..IC-C4; a pointer to an ordered cascade that omits the order invites arbitrary evaluation"
fi
# Without first-match-wins, IC-C1's priority over IC-C3 becomes non-deterministic.
if [ -s "$WORKER_STEP" ] && grep -qiE 'first match wins|first[- ]match[- ]wins|the first rule that matches' "$WORKER_STEP"; then
    pass "S2c-worker-states-first-match-wins"
else
    fail "S2c-worker-states-first-match-wins" "the worker must state first-match-wins, not merely list the rules in order"
fi
# Restating the rules is what produces the second copy S4 exists to detect.
if [ -s "$WORKER_STEP" ] && grep -qiE 'never restate|do not restate|never repeat the rules' "$WORKER_STEP"; then
    pass "S2d-worker-forbids-restating-the-rules"
else
    fail "S2d-worker-forbids-restating-the-rules" "the worker must forbid restating the cascade rules inline — that prohibition is what keeps the SSOT single"
fi
# same_fix is a table LOOKUP, not a judgment: a worker that re-judges it can disagree
# with the validator's map and get the artifact rejected.
if [ -s "$WORKER_STEP" ] && grep -qiE 'same_fix.*(table|fixed by the verdict)|(table|fixed by the verdict).*same_fix' "$WORKER_STEP"; then
    pass "S2e-worker-takes-same-fix-from-the-table"
else
    fail "S2e-worker-takes-same-fix-from-the-table" "the worker must be told to copy same_fix from the cascade table rather than judge it"
fi
if [ -s "$WORKER_STEP" ] && grep -qiE 'never judged separately|never re-?judge|not judged separately' "$WORKER_STEP"; then
    pass "S2f-worker-forbids-rejudging-same-fix"
else
    fail "S2f-worker-forbids-rejudging-same-fix" "the lookup instruction must be paired with an explicit prohibition on judging same_fix independently"
fi

# Injection, not restatement: the reviewer must read the same bytes the worker reads.
if [ -f "$CODEX_SH" ] && grep -qE 'cat[[:space:]]+"\$CASCADE_SSOT"' "$CODEX_SH"; then
    pass "S3-codex-injects-cascade-body"
else
    fail "S3-codex-injects-cascade-body" "review-survey-verdict-codex.sh must cat the cascade SSOT into the prompt"
fi

# Non-duplication checked structurally: the table's ROW FORM must exist in one file only.
for pair in "S4-worker:$WORKER_MD" "S5-codex:$CODEX_SH"; do
    label="${pair%%:*}"; f="${pair#*:}"
    table_rows "$f" > "$WORK/rows-$label.txt"
    n=$(count_lines "$WORK/rows-$label.txt")
    if [ "$n" -eq 0 ]; then
        pass "${label}-does-not-copy-the-table"
    else
        fail "${label}-does-not-copy-the-table" "found $n same_fix table rows outside the cascade SSOT: $(table_rows "$f" | tr '\n' ' ')"
    fi
done

echo ""
echo "=== R: the assembled reviewer prompt carries same_fix and the cascade ==="

# Mock codex captures the prompt on stdin — the only way to see the assembled prompt,
# since the script builds it in a 600-mode temp file and deletes it on exit.
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
printf '%s\n' 'FINAL_VERDICT_JSON:'
printf '%s\n' '{"verdict":"none","target":null,"children":[],"related":[],"reason":"no overlap","worth_filing":true,"same_fix":false}'
MOCK
chmod +x "$MOCKDIR/codex"

ART="$WORK/survey.json"
"$RWT" 15 node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  proposal: { title: "P", background: "B", changes: "C" },
  verdict: "none", target: null, children: [], related: [],
  reason: "survey reason", same_fix: false,
  relations_mode: "batched", relation_errors: [],
  candidates: [
    { number: 10, title: "c10", state: "open", labels: [], body: "b10",
      relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false }
  ]
}, null, 2));' "$(node_path "$ART")"

PROMPT="$WORK/prompt.txt"
: > "$PROMPT"
if [ -f "$CODEX_SH" ]; then
    CODEX_PROMPT_LOG="$PROMPT" PATH="$MOCKDIR:$PATH" \
        "$RWT" 60 bash "$CODEX_SH" --artifact "$ART" --out "$WORK/final.json" --no-log \
        >/dev/null 2>&1 || true
fi

first_index() { grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }

if [ -s "$PROMPT" ]; then
    pass "R1-prompt-captured"
else
    fail "R1-prompt-captured" "the mock codex received no prompt (review-survey-verdict-codex.sh present=$([ -f "$CODEX_SH" ] && echo yes || echo no))"
fi

# The JSON shape line is the output contract; same_fix elsewhere in the prompt would not
# make it a required key of the answer.
SHAPE_LINE=$(grep -F '"verdict":"<one of the above>"' "$PROMPT" 2>/dev/null | head -n 1)
if [ -n "$SHAPE_LINE" ] && printf '%s' "$SHAPE_LINE" | grep -qF 'same_fix'; then
    pass "R2-same-fix-on-the-json-shape-line"
else
    fail "R2-same-fix-on-the-json-shape-line" "the output-shape line must require same_fix (got: '${SHAPE_LINE:-<no shape line>}')"
fi

# Parsing the PROMPT with the cascade's parser proves the rows arrived intact, not just
# that some prose did.
PROMPT_ROWS="$WORK/prompt-rows.txt"
table_rows "$PROMPT" > "$PROMPT_ROWS"
if [ "$CROWS" -eq 5 ] && diff -q "$CASCADE_ROWS" "$PROMPT_ROWS" >/dev/null 2>&1; then
    pass "R3-cascade-table-reaches-the-prompt"
else
    fail "R3-cascade-table-reaches-the-prompt" "prompt rows=[$(tr '\n' ' ' < "$PROMPT_ROWS")] cascade rows=[$(tr '\n' ' ' < "$CASCADE_ROWS")]"
fi

# Prompt-injection ordering (predates #1912): the rules must be established BEFORE any
# attacker-controlled issue body is read.
TI=$(first_index "$PROMPT" 'make-parent')
CI=$(first_index "$PROMPT" '[CANDIDATES START]')
if [ -n "$TI" ] && [ -n "$CI" ] && [ "$TI" -lt "$CI" ]; then
    pass "R4-cascade-precedes-the-untrusted-block"
else
    fail "R4-cascade-precedes-the-untrusted-block" "cascade line=${TI:-<absent>} candidates marker=${CI:-<absent>} (cascade must come first)"
fi


# --- sections ------------------------------------------------------------------------
# Split out to stay under the 500-line HARD limit (rules/coding/file-split.md):
#   icc1-semantics.sh        properties of the NEW IC-C1 criterion
#   ssot-injection-parity.sh both graders receive the SAME cascade bytes
# run-all.sh globs tests/*.sh only, so sections run via tests/lib/section-runner.sh.
SECTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feat-1912-verdict-criterion-drift"
# shellcheck source=./lib/section-runner.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/section-runner.sh"

run_section "icc1-semantics.sh" 120
run_section "ssot-injection-parity.sh" 240

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
