#!/usr/bin/env bash
# tests/feat-1912-verdict-criterion-drift/icc1-semantics.sh
# Tests: skills/_shared/issue-verdict-cascade.md
# Tags: issue-create, verdict, cascade, icc1, same-fix, doc-contract, ssot, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether a real grader OBEYS the criterion. Only a real-model run could show that;
#   #1912 accepted that residual risk explicitly. What is pinnable is that the criterion
#   the graders are handed still says what #1912 decided it should say.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Section of tests/feat-1912-verdict-criterion-drift.sh (subprocess; tests/lib/section-runner.sh).
#
# Why this file exists (CPR-WPH): #1912 REPLACED the IC-C1 criterion. The old one asked
# whether two issues shared a root cause *or* an observed symptom; the new one asks
# whether ONE fix resolves the proposal and the candidate AT THE SAME TIME. The parent
# file pins fragments of that sentence (O2–O7) and the negative directive (N1–N3). What
# neither pins is the criterion as a SEMANTIC WHOLE — the four properties that together
# make it decidable. A rewrite that kept every phrase the parent greps for while dropping
# one of these four would leave a criterion a grader cannot apply.
#
#   (a) simultaneity      one fix, both items, at the same time — not two fixes in a row
#   (b) cause identity    the shared thing is the underlying cause, not the appearance
#   (c) symptom exclusion symptom similarity ALONE is named and refused, for reopen
#   (d) reason contract   `reason` is required, and when same_fix is true it must make
#                         the single covering fix identifiable — otherwise "one fix
#                         covers both" is an unfalsifiable claim
#
# Every case is section-scoped (CPR-SC). (a)–(c) read the IC-C1 block; (d) reads the
# block that owns the `reason` contract. A whole-file grep would let a sentence sitting
# anywhere in the cascade satisfy an assertion about IC-C1 — and this file's sibling has
# a live example of exactly that (see M6 in the parent).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASCADE="$AGENTS_DIR/skills/_shared/issue-verdict-cascade.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# md_section <file> <heading-regex> → body of that `## ` section (headings excluded).
md_section() {
    [ -f "$1" ] || return 0
    awk -v re="$2" '
      /^##[[:space:]]/ { inb = ($0 ~ re) ? 1 : 0; next }
      inb { print }' "$1"
}

ICC1="$WORK/icc1.txt"; ICC1_FLAT="$WORK/icc1-flat.txt"
md_section "$CASCADE" '^##[[:space:]]+IC-C1' > "$ICC1" 2>/dev/null || : > "$ICC1"
tr '\n' ' ' < "$ICC1" > "$ICC1_FLAT" 2>/dev/null || : > "$ICC1_FLAT"

# The `reason` contract does not live under a heading of its own — it is a bullet in the
# auxiliary rules. Locate it by its subject rather than by section name, so a reshuffle of
# the cascade's headings does not turn a present contract into a reported-missing one, and
# flatten the bullet (it wraps) before matching.
REASON_RULE="$WORK/reason-rule.txt"
: > "$REASON_RULE"
if [ -f "$CASCADE" ]; then
    awk '/^-?[[:space:]]*`reason`/ { inb = 1; buf = $0; next }
         inb && /^-[[:space:]]/ { inb = 0 }
         inb { buf = buf " " $0 }
         END { if (buf != "") print buf }' "$CASCADE" > "$REASON_RULE" 2>/dev/null || true
fi

echo "=== Q: the IC-C1 criterion as a semantic whole (4 properties) ==="

# Non-vacuity gate. Every case below reads one of the two extracted blocks; if extraction
# silently produced nothing, a `grep -q` on an empty file fails for the wrong reason and
# the failure message would send the next reader after the wrong defect.
if [ -s "$ICC1" ]; then
    pass "Q0-icc1-block-extracted"
else
    fail "Q0-icc1-block-extracted" "no '## IC-C1' section body found in $CASCADE — Q1..Q3 below read that block"
fi
if [ -s "$REASON_RULE" ]; then
    pass "Q0b-reason-rule-extracted"
else
    fail "Q0b-reason-rule-extracted" "no \`reason\` rule found in $CASCADE — Q4/Q5 read that rule"
fi

# (a) SIMULTANEITY. The whole point of the rewrite: "one fix resolves both" is also true
# of two issues a single PR happens to touch in sequence. The criterion must bind the two
# resolutions to the SAME fix event, and it must name both sides of what is resolved.
if grep -qiE 'one fix[^.?]*(resolve|fix|close)[^.?]*(this proposal|the proposal)[^.?]*(candidate|issue)[^.?]*(at the same time|simultaneous)' "$ICC1_FLAT"; then
    pass "Q1-criterion-is-one-fix-both-sides-at-the-same-time"
else
    fail "Q1-criterion-is-one-fix-both-sides-at-the-same-time" "IC-C1 must ask, in one sentence, whether ONE fix resolves the proposal AND the candidate AT THE SAME TIME; block: $(cat "$ICC1_FLAT")"
fi

# (a′) The criterion has to be the DECIDING question, not a remark. Without this an
# editor could relegate the sentence to an aside and Q1 would still pass.
if grep -qiE '(ask|answer)[^.?]*(question|one fix)|if the answer is yes[^.]*(decide|reopen)' "$ICC1_FLAT"; then
    pass "Q2-criterion-is-posed-as-the-deciding-question"
else
    fail "Q2-criterion-is-posed-as-the-deciding-question" "the one-fix sentence must be posed as the question IC-C1 decides by, not stated as an aside; block: $(cat "$ICC1_FLAT")"
fi

# (b) CAUSE IDENTITY. What makes one fix able to close both is that the thing being fixed
# is the same thing. IC-C1 must say so in terms of the underlying/root cause — the word
# that separates "the same defect" from "two defects that look alike".
if grep -qiE '(underlying|root)[- ]?cause' "$ICC1_FLAT"; then
    pass "Q3-criterion-rests-on-cause-identity"
else
    fail "Q3-criterion-rests-on-cause-identity" "IC-C1 must ground the match in the underlying/root cause, not in appearance; block: $(cat "$ICC1_FLAT")"
fi

# (b′) And the cause must be tied to the consequence that makes it decidable: differing
# causes mean two fixes. A bare mention of "root cause" with no consequence is decoration.
if grep -qiE '(underlying|root)[- ]?cause[^.]*(differ|different|not the same)[^.]*(two|separate|distinct)[^.]*fix' "$ICC1_FLAT" \
   || grep -qiE '(two|separate|distinct)[^.]*fix[^.]*(underlying|root)[- ]?cause[^.]*(differ|different)' "$ICC1_FLAT"; then
    pass "Q3b-differing-causes-mean-two-fixes"
else
    fail "Q3b-differing-causes-mean-two-fixes" "IC-C1 must state the consequence of the cause test — different underlying causes need two separate fixes; block: $(cat "$ICC1_FLAT")"
fi

# (c) SYMPTOM EXCLUSION. The retired criterion offered the symptom as an ALTERNATIVE
# ground. The replacement must refuse it by name, in the negative, and must say what it is
# refusing it FOR (reopen) — a general "symptoms are not enough" attached to no verdict
# constrains nothing. The word ALONE is the substance: symptoms remain admissible evidence,
# they are just not sufficient on their own.
if grep -qiE 'symptom[^.]*(alone|only|by itself|on its own)[^.]*(must never|never|must not|do not)' "$ICC1_FLAT" \
   || grep -qiE '(must never|never|must not|do not)[^.]*symptom[^.]*(alone|only|by itself|on its own)' "$ICC1_FLAT"; then
    pass "Q4-symptom-similarity-alone-is-refused"
else
    fail "Q4-symptom-similarity-alone-is-refused" "IC-C1 must refuse symptom similarity ALONE in the negative — 'alone' is what keeps symptoms admissible as evidence while denying them sufficiency; block: $(cat "$ICC1_FLAT")"
fi

if grep -qiE 'symptom[^.]*reopen|reopen[^.]*symptom' "$ICC1_FLAT"; then
    pass "Q4b-symptom-refusal-names-reopen"
else
    fail "Q4b-symptom-refusal-names-reopen" "the symptom refusal must name the verdict it constrains (reopen), or it constrains nothing; block: $(cat "$ICC1_FLAT")"
fi

echo ""
echo "=== Q5/Q6: the reason contract makes the one-fix claim falsifiable ==="

# (d) REASON REQUIRED. `same_fix: true` asserts that one fix covers both. An assertion no
# reader can check is not a contract, and the review stage's whole job is checking. The
# cascade must therefore require a `reason`, and require that it identify the rule.
if grep -qiE '`?reason`?[^.]*(one sentence|required|must)' "$REASON_RULE" \
   && grep -qiE 'rule[^.]*identifiab|identifiab[^.]*rule' "$REASON_RULE"; then
    pass "Q5-reason-is-required-and-identifies-the-rule"
else
    fail "Q5-reason-is-required-and-identifies-the-rule" "the cascade must require a \`reason\` that makes the matching rule identifiable; rule: $(cat "$REASON_RULE")"
fi

# (d′) The conditional half, which is the #1912 addition: when same_fix is true, the
# reason must make THE SINGLE COVERING FIX identifiable. Without this the field records a
# claim ("one fix covers both") with no way to tell whether the grader had a fix in mind.
if grep -qiE 'same_fix[^.]*(true)[^.]*(single|one)[^.]*fix[^.]*identifiab' "$REASON_RULE" \
   || grep -qiE '(single|one)[^.]*fix[^.]*identifiab[^.]*same_fix[^.]*true' "$REASON_RULE"; then
    pass "Q6-true-same-fix-requires-an-identifiable-single-fix"
else
    fail "Q6-true-same-fix-requires-an-identifiable-single-fix" "when same_fix is true the reason must make the single covering fix identifiable — otherwise the field asserts something nobody can check; rule: $(cat "$REASON_RULE")"
fi

# Counterweight (non-vacuity of Q6): the conditional must be conditional. A cascade that
# demanded the single-fix identification on EVERY verdict would be asking the grader to
# name a fix that, for the four false verdicts, does not exist.
if grep -qiE 'when[^.]*same_fix[^.]*true|same_fix[^.]*is[^.]*`?true`?[^.]*(so|then)' "$REASON_RULE"; then
    pass "Q6b-single-fix-requirement-is-conditional-on-same-fix"
else
    fail "Q6b-single-fix-requirement-is-conditional-on-same-fix" "the single-fix identification must be scoped to same_fix=true; on a false verdict there is no single covering fix to name; rule: $(cat "$REASON_RULE")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
