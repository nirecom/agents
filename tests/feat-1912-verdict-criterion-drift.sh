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
# Two copies of a decision table are one copy too many. `same_fix` now exists in three
# places that must agree: the human-and-model-readable table in the cascade SSOT, the
# machine-readable map in the validator, and the prompt the reviewer actually receives.
# Any pair silently disagreeing produces the worst failure mode available here — a
# verdict that is structurally valid and substantively wrong. This file pins the
# agreement itself rather than any one copy.
#
# The comparison is deliberately a SUBSET comparison: `bulk-sub-of` lives in the JS map
# (the artifact grammar admits it) but must NOT appear in the cascade table (the review
# grammar does not). A naive "the two are equal" assertion would fail forever.

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
# Every doc-contract case below asserts something about ONE section of the cascade, so it
# must read that section and nothing else. A whole-file grep is satisfied by an unrelated
# occurrence elsewhere, and this file has a live example of the failure mode: the phrase
# "sub-of ... meta parent" appears in the IC-C2 HEADING ("sub-of (attach to an existing
# meta parent)"), so a whole-file M6 reports "the same_fix section states its reason"
# while reading a heading that states nothing of the kind.
#
# Both a line-oriented copy and a flattened copy are produced per section: a line grep is
# the right tool for a table row or a directive that must stand alone, and a flattened
# copy is the right tool for a sentence the file wraps across several lines.
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

# table_rows <file> → sorted `verdict=bool` lines for every fixed 2-column markdown row.
# Backticks and whitespace are stripped so the table may be written either way; a row
# whose second column is not a bare boolean (the `|---|---|` separator, or a prose
# table) is skipped rather than mis-parsed into a phantom pair.
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

# P1 exists so P3 cannot pass vacuously: two empty lists are "equal" and would report
# agreement between a table that is not there and a map that is not there.
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

# The asymmetry is intentional and must be visible in BOTH directions: absent from the
# doc table, present in the map. Asserting only one side would let a well-meaning edit
# "complete" the table and reintroduce a verdict the reviewer may not answer with.
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

# Deliberately independent of the awk parser above. If the table's shape changes in a
# way the parser cannot read, P3 turns into a parse complaint and this case still says
# plainly whether the one value #1912 reverses is written down correctly.
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
# Flattened before matching: the rationale is a paragraph the file wraps across several
# lines, so a line-oriented grep would report a present reason as missing purely because
# of where the paragraph happens to break. Scoped to the `same_fix` section (see the
# section-scoping note above): the reason has to sit with the table it explains, not
# somewhere else in the file where a reader deciding a verdict will never meet it.
if grep -qiE 'make-parent[^.]*(own fix|its own|each [^.]*fix)|(own fix|each keeps)[^.]*make-parent' "$SAMEFIX_FLAT"; then
    pass "M3-make-parent-false-has-a-stated-reason"
else
    fail "M3-make-parent-false-has-a-stated-reason" "the text after the table must say why make-parent is false (children each carry their own fix)"
fi

# --- sub-of: the value #1912 reverses on the parent-ATTACHING side ----------------------
# CPR-ORTH: sub-of and make-parent both name a meta parent, so the pin that guards one
# must guard the other. Kept standalone for the same reason M1/M2 are: if the table's
# shape stops parsing, P3 degrades to a parse complaint and these still speak plainly.
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

# The two `false` rows must share ONE stated reason, not two coincidences: the issue a
# parent-attaching verdict names is a meta parent, a container never implemented against.
# Without this the next editor sees two unrelated values and 'corrects' one of them.
#
# Scoped to the `same_fix` section, and that scoping is load-bearing rather than tidiness:
# read against the whole file this case is satisfied by the IC-C2 HEADING, "sub-of (attach
# to an existing meta parent)", which names a route and explains nothing. The reason may be
# written collectively ("both parent-attaching verdicts …") or per-verdict, so both forms
# are accepted — but the section must also NAME sub-of, or the collective sentence could be
# about anything.
if grep -qiE '(sub-of|parent-attaching)[^.]*(meta parent|never implemented|container)|(meta parent|never implemented|container)[^.]*(sub-of|parent-attaching)' "$SAMEFIX_FLAT" \
   && grep -qF 'sub-of' "$SAMEFIX_FLAT"; then
    pass "M6-sub-of-false-has-a-stated-reason"
else
    fail "M6-sub-of-false-has-a-stated-reason" "the same_fix section must say why sub-of is false (it attaches to a meta parent, which is never implemented against); section: $(cat "$SAMEFIX_FLAT")"
fi

echo ""
echo "=== N: symptom similarity alone does not justify reopen ==="

# IC-C1's old wording read 'same root cause OR observed symptom', and the OR is what
# let a symptom match carry a reopen on its own. The replacement must say so in the
# negative, on its own line — a positive restatement of the root-cause test does not
# stop a grader that already believes the symptom is enough.
#
# All three cases read the IC-C1 BLOCK, not the file. The rule they describe is IC-C1's
# rule; a prohibition parked in a later section is one the grader deciding IC-C1 has
# already walked past, and a whole-file grep cannot tell the two apart.
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

# Why this group exists as a separate one: N asserts the negative sentence ("symptom
# similarity alone never carries a reopen"). A negative alone does not tell a grader what
# DOES carry a reopen — delete the positive rule and keep the negative, and every case in
# N still passes while the cascade has lost its criterion entirely. #1912's change is the
# positive sentence; that is what has to be pinned, and pinned INSIDE the IC-C1 block,
# because the same wording also appears in the `same_fix` section further down (which is
# about copying a table value, not about deciding a verdict).
# $ICC1 / $ICC1_FLAT are extracted once near the top of this file (section-scoping note).
# The flattened copy exists because the criterion is a single sentence that the file wraps
# across three lines, and a line-oriented grep would report it missing purely because of
# where the paragraph happens to break.
if [ -s "$ICC1" ]; then
    pass "O1-icc1-block-is-extractable"
else
    fail "O1-icc1-block-is-extractable" "no '## IC-C1' section found in $CASCADE — every case below reads that block"
fi

# The criterion itself: ONE fix, BOTH items, AT THE SAME TIME. All three parts are
# required, and each is asserted separately so the failure message names the missing one.
# "one fix" alone would also match "one fix per issue"; the conjunction is the substance.
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
# The criterion has to be operative — an instruction to decide, not a description. A
# grader reading a definition with no imperative has been told nothing to do.
if grep -qiE '(decide|choose|answer)[^.]*reopen|reopen[^.]*(decide|choose)' "$ICC1_FLAT"; then
    pass "O5-icc1-criterion-drives-the-reopen-decision"
else
    fail "O5-icc1-criterion-drives-the-reopen-decision" "the IC-C1 block must instruct the grader to DECIDE reopen when the criterion holds"
fi
# One candidate is enough. Without this, "does one fix resolve the proposal and the
# candidates" could be read as requiring the whole set to match.
if grep -qiE 'even one candidate|any candidate|for one candidate' "$ICC1_FLAT"; then
    pass "O6-icc1-one-matching-candidate-suffices"
else
    fail "O6-icc1-one-matching-candidate-suffices" "IC-C1 must say a single matching candidate is enough to decide reopen"
fi

# The retired formulation, in the negative. The pre-#1912 wording made root cause and
# observed symptom alternatives ('or'), and that disjunction is precisely what let a
# symptom match carry a reopen. Restricted to the IC-C1 block: the word "symptom" still
# legitimately appears there in the negative sentence N asserts.
if grep -qiE '(root cause|underlying cause)[^.]*\bor\b[^.]*symptom|symptom[^.]*\bor\b[^.]*(root cause|underlying cause)' "$ICC1_FLAT"; then
    fail "O7-retired-cause-or-symptom-disjunction-absent" "IC-C1 still offers root cause OR symptom as alternatives — this is the pre-#1912 criterion #1912 replaced"
else
    pass "O7-retired-cause-or-symptom-disjunction-absent"
fi

# The two places that phrase the criterion must phrase it the SAME way, or a grader who
# reads only one of them decides on different grounds than one who reads the other.
if [ -s "$SAMEFIX_BLOCK" ] && grep -qiE 'one[[:space:]]*fix' "$SAMEFIX_BLOCK" \
   && grep -qiE 'IC-C1' "$SAMEFIX_BLOCK"; then
    pass "O8-same-fix-section-defers-to-the-icc1-criterion"
else
    fail "O8-same-fix-section-defers-to-the-icc1-criterion" "the same_fix section must state that it answers the IC-C1 question, so the two definitions cannot drift apart"
fi

echo ""
echo "=== S: both graders reference the SSOT, neither duplicates the table ==="

# The worker's cascade instruction is ONE numbered procedure step. S2b–S2f below assert
# what that step says, so they must read that step: "never restate" written in a rules
# bullet at the bottom of the file, or "first match wins" quoted in an unrelated example,
# would satisfy a whole-file grep while the step the worker actually executes said neither.
# The block is self-locating — it starts at the line naming the SSOT and ends at the next
# numbered step — so renumbering the procedure cannot silently empty it.
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

# S4/S5 below prove the worker does not COPY the cascade. That is only half the contract:
# a worker that copies nothing and says nothing about how to use the file it was pointed
# at is equally broken, and the S1/S2 path-and-field checks would not notice. S2b–S2e pin
# the four instructions that make the pointer usable — they are the entire mechanism by
# which the SSOT reaches the survey side.
if [ -s "$WORKER_STEP" ] && grep -qE 'IC-C1,[[:space:]]*IC-C2,[[:space:]]*IC-C3,[[:space:]]*IC-C4' "$WORKER_STEP"; then
    pass "S2b-worker-states-the-cascade-order"
else
    fail "S2b-worker-states-the-cascade-order" "the worker must name the evaluation order IC-C1..IC-C4; a pointer to an ordered cascade that omits the order invites arbitrary evaluation"
fi
# Without first-match-wins, a grader that finds two matching rules picks either one, and
# IC-C1's priority over IC-C3 (the reopen-vs-group decision) becomes non-deterministic.
if [ -s "$WORKER_STEP" ] && grep -qiE 'first match wins|first[- ]match[- ]wins|the first rule that matches' "$WORKER_STEP"; then
    pass "S2c-worker-states-first-match-wins"
else
    fail "S2c-worker-states-first-match-wins" "the worker must state first-match-wins, not merely list the rules in order"
fi
# The instruction that makes S4 enforceable at authoring time: restating the rules is
# what produces the second copy S4 exists to detect.
if [ -s "$WORKER_STEP" ] && grep -qiE 'never restate|do not restate|never repeat the rules' "$WORKER_STEP"; then
    pass "S2d-worker-forbids-restating-the-rules"
else
    fail "S2d-worker-forbids-restating-the-rules" "the worker must forbid restating the cascade rules inline — that prohibition is what keeps the SSOT single"
fi
# same_fix is a table LOOKUP, not a judgment. A worker that re-judges it can disagree
# with the validator's map for the same verdict, and the artifact is then rejected for a
# field the grader was never supposed to reason about.
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

# Non-duplication is checked structurally: the table's ROW FORM must exist in exactly
# one file. A second copy is the copy that drifts, and it drifts silently.
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

# Mock codex captures the prompt on stdin. This is the only way to see the prompt the
# reviewer is actually handed: the script builds it in a 600-mode temp file and deletes
# it on exit, so reading the script's source would only prove intent, not the result.
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

# The JSON shape line is the reviewer's output contract. same_fix appearing anywhere
# else in the prompt would not make it a required key of the answer.
SHAPE_LINE=$(grep -F '"verdict":"<one of the above>"' "$PROMPT" 2>/dev/null | head -n 1)
if [ -n "$SHAPE_LINE" ] && printf '%s' "$SHAPE_LINE" | grep -qF 'same_fix'; then
    pass "R2-same-fix-on-the-json-shape-line"
else
    fail "R2-same-fix-on-the-json-shape-line" "the output-shape line must require same_fix (got: '${SHAPE_LINE:-<no shape line>}')"
fi

# The table has to survive the trip. Parsing the PROMPT with the same parser used on
# the cascade proves the rows arrived intact, not merely that some prose did.
PROMPT_ROWS="$WORK/prompt-rows.txt"
table_rows "$PROMPT" > "$PROMPT_ROWS"
if [ "$CROWS" -eq 5 ] && diff -q "$CASCADE_ROWS" "$PROMPT_ROWS" >/dev/null 2>&1; then
    pass "R3-cascade-table-reaches-the-prompt"
else
    fail "R3-cascade-table-reaches-the-prompt" "prompt rows=[$(tr '\n' ' ' < "$PROMPT_ROWS")] cascade rows=[$(tr '\n' ' ' < "$CASCADE_ROWS")]"
fi

# Order matters for prompt-injection reasons that predate #1912: the rules must be
# established BEFORE any attacker-controlled issue body is read.
TI=$(first_index "$PROMPT" 'make-parent')
CI=$(first_index "$PROMPT" '[CANDIDATES START]')
if [ -n "$TI" ] && [ -n "$CI" ] && [ "$TI" -lt "$CI" ]; then
    pass "R4-cascade-precedes-the-untrusted-block"
else
    fail "R4-cascade-precedes-the-untrusted-block" "cascade line=${TI:-<absent>} candidates marker=${CI:-<absent>} (cascade must come first)"
fi


# --- sections ------------------------------------------------------------------------
# Two concerns too large for this file (already ~450 lines, rules/coding/file-split.md
# HARD limit 500):
#   icc1-semantics.sh        the four properties of the NEW IC-C1 criterion
#   ssot-injection-parity.sh the two graders receive the SAME cascade bytes
# tests/run-all.sh globs tests/*.sh (top level only), so without this block neither
# would ever run — see tests/lib/section-runner.sh.
SECTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feat-1912-verdict-criterion-drift"
# shellcheck source=./lib/section-runner.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/section-runner.sh"

run_section "icc1-semantics.sh" 120
run_section "ssot-injection-parity.sh" 240

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
