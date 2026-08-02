#!/usr/bin/env bash
# tests/feat-1763-confirm-gate-matrix.sh
# Tests: skills/issue-create/scripts/eval-confirm-gate.sh, skills/issue-create/SKILL.md
# Tags: issue-create, confirm-gate, truth-table, worth-filing, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The skill actually raising AskUserQuestion when the script says "confirm: yes".
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# The confirm gate is the logical OR of four independent conditions:
#   G1  final verdict touches EXISTING issues            (destructive / restructuring)
#       reopen | make-parent | sub-of | bulk-sub-of — all four re-parent or reopen
#       something that already exists, and sub-of/bulk-sub-of can reopen every closed
#       ancestor of the parent chain, so they are not the "additive" case (CPR-5).
#   G2  the review stage replaced the survey verdict     (survey != review)
#   G3  the reviewer did not affirm the issue is worth filing — unless the answer never
#       reached the gate at all (worth_filing absent/unreadable) AND severity is high
#   G4  review_result is invalid or skipped              (unverified verdict)
# Contract: eval-confirm-gate.sh <final-json> <severity-label>   (exactly 2 arguments)
#   <final-json>  = the review `--out` artifact (survey.verdict / review.status /
#                   review.worth_filing all live there)
#   stdout line 1: "confirm: yes" | "confirm: no"
#   stdout line 2: "reasons: G1,G3"  (empty list => "reasons: ")
#   exit 0 when it classifies — the caller decides, the script only classifies.
#   exit non-zero ONLY on a wrong argument count (see section A).
#
# G3's input changed (#1763): it used to read a provenance token minted by a hook, which
# meant the gate had a second, out-of-band input and a whole token lifecycle behind it.
# It now reads `review.worth_filing` — the reviewer's own boolean, carried in the same
# artifact as everything else the gate reads. The gate therefore became a pure function
# of two arguments, which is what the whole of this file relies on: no session state, no
# replay environment, no marker files.
#
# The reading is deliberately fail-closed: only a literal boolean `true` counts as "the
# reviewer affirmed it". Missing, null, stringified and numeric values all mean "no
# affirmation reached me", which is the case G3 exists for.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$AGENTS_DIR/skills/issue-create/scripts/eval-confirm-gate.sh"
SKILL="$AGENTS_DIR/skills/issue-create/SKILL.md"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

GATE_PRESENT=no; [ -f "$GATE" ] && GATE_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mk_json <file> <final-verdict> <survey-verdict> <review-status> <worth-filing-json|__OMIT__>
# Shape is the review `--out` artifact — the ONLY thing the main conversation reads.
# Note what is deliberately absent: no `proposal`, no `provenance`, and `candidates[]`
# carries only number/title/state (never `body`). The gate must not need any of them.
mk_json() {
    V="$2" SV="$3" RST="$4" WF="$5" node -e "
const fs=require('fs');
const review = { status: process.env.RST, verdict: process.env.V, target: null,
                 children: [], related: [], reason: 'r', detail: '' };
if (process.env.WF !== '__OMIT__') review.worth_filing = JSON.parse(process.env.WF);
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  verdict: process.env.V, target: null, children: [], related: [], reason: 'r',
  survey: { verdict: process.env.SV, target: null, children: [], related: [], reason: 's' },
  review,
  candidates: [{ number: 1, title: 't', state: 'open' }]
}, null, 2));" "$1"
}

# run_gate <json> <severity> → sets CONFIRM / REASONS / RC
run_gate() {
    if [ "$GATE_PRESENT" != "yes" ]; then CONFIRM="<missing>"; REASONS="<missing>"; RC=127; return; fi
    local out
    out=$("$RWT" 20 bash "$GATE" "$1" "$2" 2>"$WORK/gate-stderr.txt")
    RC=$?
    CONFIRM=$(printf '%s\n' "$out" | sed -n 's/^confirm: *//p' | head -n 1 | tr -d '[:space:]')
    REASONS=$(printf '%s\n' "$out" | sed -n 's/^reasons: *//p' | head -n 1 | tr -d '[:space:]')
}

# assert_row <name> <verdict> <survey> <review-status> <worth-filing> <severity> <want-confirm> <want-reasons>
assert_row() {
    local name="$1" want_c="$7" want_r="$8"
    local jf="$WORK/$name.json"
    mk_json "$jf" "$2" "$3" "$4" "$5"
    run_gate "$jf" "$6"
    if [ "$CONFIRM" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: skills/issue-create/scripts/eval-confirm-gate.sh not yet created"
        return
    fi
    if [ "$RC" -ne 0 ]; then
        fail "$name" "want exit 0 (a well-formed 2-argument call always classifies), got $RC: $(head -n 1 "$WORK/gate-stderr.txt" 2>/dev/null)"
        return
    fi
    if [ "$CONFIRM" != "$want_c" ]; then
        fail "$name" "confirm want=$want_c got=$CONFIRM (reasons=$REASONS)"
        return
    fi
    # Compare reason sets order-insensitively.
    local got_sorted want_sorted
    got_sorted=$(printf '%s' "$REASONS"  | tr ',' '\n' | grep -v '^$' | sort | paste -sd, -)
    want_sorted=$(printf '%s' "$want_r"  | tr ',' '\n' | grep -v '^$' | sort | paste -sd, -)
    if [ "$got_sorted" = "$want_sorted" ]; then
        pass "$name"
    else
        fail "$name" "reasons want=[$want_sorted] got=[$got_sorted]"
    fi
}

echo "=== truth table: verdict | survey | review_result | worth_filing | severity ==="
# name                       verdict      survey       review    worth  severity        confirm reasons
assert_row T01-none-clean    none         none         upheld    true   severity:low    no      ""
assert_row T02-sibling-clean sibling      sibling      upheld    true   severity:low    no      ""

echo ""
echo "--- G1: verdicts that touch existing issues always confirm ---"
assert_row T04-reopen        reopen       reopen       upheld    true   severity:low    yes     "G1"
assert_row T05-make-parent   make-parent  make-parent  upheld    true   severity:high   yes     "G1"
# sub-of and bulk-sub-of are in the same class: attaching under a parent can reopen every
# closed ancestor of that parent chain, which is exactly the "changes something that
# already exists" property G1 names. Treating them as additive would have let the one
# verdict that silently reopens issues through without a question.
assert_row T03-subof-clean   sub-of       sub-of       upheld    true   severity:medium yes     "G1"
assert_row T19-bulk-subof    bulk-sub-of  bulk-sub-of  upheld    true   severity:low    yes     "G1"

echo ""
echo "--- G2: the review stage replaced the survey verdict ---"
assert_row T06-replaced      sibling      none         replaced  true   severity:low    yes     "G2"
assert_row T07-replaced-subof sub-of      sibling      replaced  true   severity:medium yes     "G1,G2"

echo ""
echo "--- G3: the reviewer did not affirm worth_filing ---"
assert_row T08-notworth-low     none      none         upheld    false  severity:low    yes     "G3"
assert_row T09-notworth-medium  none      none         upheld    false  severity:medium yes     "G3"
# The carve-out is narrow: severity:high stands in for a worth_filing the gate never
# received — absent, null, or otherwise unreadable — where a high-severity proposal is
# worth filing anyway and the question would buy nothing. It does NOT overrule a reviewer
# who read the evidence and concluded worth_filing:false; that is an answer, not a gap,
# and silently discarding it would file the duplicate the reviewer just identified.
assert_row T10-notworth-high    none      none         upheld    false  severity:high   yes     "G3"
assert_row T11-worth-high       none      none         upheld    true   severity:high   no      ""

echo ""
echo "--- G4: an unverified verdict always confirms ---"
# worth_filing is pinned `true` here so that G4 is the only condition in play; T16/T22
# below cover the realistic combination where a failed review carries no opinion either.
assert_row T12-review-invalid none        none         invalid   true   severity:low    yes     "G4"
assert_row T13-review-skipped none        none         skipped   true   severity:high   yes     "G4"
# A review that never completed has no worth_filing to report — null is what the wrapper
# writes — so the honest artifact fires both G3 and G4 at once.
assert_row T22-skipped-null-worth none     none        skipped   null   severity:low    yes     "G3,G4"

# T20/T21 — the no-Node degraded path in review-survey-verdict-codex.sh writes the final
# artifact by COPYING the survey artifact, so what reaches the gate has no `review`
# object at all. That path is only safe because the gate reads a missing review.status
# the same way it reads `invalid`: nobody reviewed this. G4 stated as an allowlist is
# what makes that true; stated as a denylist of {invalid, skipped} it would be false,
# and the one environment without node would be the one that skips the question.
# Both run at severity:high so that G4 is isolated from G3.
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "T20-no-review-object-fires-G4" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "T21-review-without-status-fires-G4" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    # Faithful to the copy: proposal and candidate bodies are still present, because the
    # degraded path never got to strip them. The gate must not need either.
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  proposal: { title: 't', background: 'b', changes: 'c' },
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  candidates: [{ number: 1, title: 't', state: 'open', body: 'b1', labels: [] }]
}, null, 2));" "$WORK/nonode.json"
    run_gate "$WORK/nonode.json" severity:high
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "T20-no-review-object-fires-G4"
    else
        fail "T20-no-review-object-fires-G4" "an artifact with no review object means no review happened (confirm=$CONFIRM, reasons=$REASONS)"
    fi

    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  survey: { verdict: 'none', target: null, children: [], related: [], reason: 's' },
  review: { detail: 'partially written', verdict: null, target: null, worth_filing: true },
  candidates: [{ number: 1, title: 't', state: 'open' }]
}, null, 2));" "$WORK/nostatus.json"
    run_gate "$WORK/nostatus.json" severity:high
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "T21-review-without-status-fires-G4"
    else
        fail "T21-review-without-status-fires-G4" "a review object without a status is not a completed review (confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "--- OR semantics: overlapping conditions accumulate reasons ---"
assert_row T14-G1-G2         reopen       none         replaced  true   severity:low    yes     "G1,G2"
assert_row T15-G1-G3         make-parent  make-parent  upheld    false  severity:low    yes     "G1,G3"
assert_row T16-G3-G4         none         none         skipped   false  severity:low    yes     "G3,G4"
assert_row T17-all-four      reopen       none         invalid   false  severity:low    yes     "G1,G2,G3,G4"
assert_row T18-G1-G4-high    reopen       reopen       skipped   false  severity:high   yes     "G1,G3,G4"

echo ""
echo "=== G3 fail-closed: anything that is not boolean true is not an affirmation ==="
# `worth_filing` crosses two boundaries before it gets here: a model writes it, and a
# shell reads it out of JSON. Both are places where a boolean quietly becomes a string.
# The dangerous default is to treat "not literal false" as affirmation — the gate would
# then stay silent for exactly the cases where the reviewer's answer was lost.
assert_failclosed() {  # <name> <worth-filing-json|__OMIT__>
    local name="$1" jf="$WORK/fc-$1.json"
    mk_json "$jf" none none upheld "$2"
    run_gate "$jf" severity:low
    if [ "$CONFIRM" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: skills/issue-create/scripts/eval-confirm-gate.sh not yet created"
    elif [ "$RC" -ne 0 ]; then
        fail "$name" "want exit 0 (a well-formed 2-argument call always classifies), got $RC"
    elif [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G3'; then
        pass "$name"
    else
        fail "$name" "an unusable worth_filing must fall to the confirm side via G3 (confirm=$CONFIRM, reasons=$REASONS)"
    fi
}

assert_failclosed P1-worth-filing-omitted   __OMIT__
assert_failclosed P2-worth-filing-null      null
assert_failclosed P3-worth-filing-string    '"true"'
assert_failclosed P4-worth-filing-number    1
assert_failclosed P5-worth-filing-empty-str '""'
assert_failclosed P6-worth-filing-space-str '"  "'
assert_failclosed P7-worth-filing-object    '{"value":true}'
# The counterpart that keeps P1-P7 from being satisfied by a gate that fires G3 always:
# a real boolean true, same shape otherwise, must NOT fire it.
assert_row P8-worth-filing-real-true none none upheld true severity:low no ""

echo ""
echo "=== A: argument arity is enforced, not silently reinterpreted ==="
# The gate used to take three arguments (<final-json> <provenance> <severity>). With
# provenance gone, an un-migrated 3-argument caller would hand the OLD provenance value
# where the severity is now read — silently classifying every issue against a severity
# label that is really "user-explicit". A wrong argument count is therefore a hard error
# rather than something to fail-safe around: fail-safe here would hide the mis-wiring for
# as long as the wrong answer happened to be `confirm: yes`.
assert_arity_error() {  # <name> <args...>
    local name="$1"; shift
    if [ "$GATE_PRESENT" != "yes" ]; then
        fail "$name" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
        return
    fi
    local out rc
    out=$("$RWT" 20 bash "$GATE" "$@" 2>"$WORK/arity-stderr.txt"); rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$name" "a wrong argument count must exit non-zero (got rc=0, out=$(printf '%s' "$out" | tr '\n' ' '))"
    elif [ ! -s "$WORK/arity-stderr.txt" ]; then
        fail "$name" "exited $rc but printed no diagnostic — the caller cannot tell what it got wrong"
    else
        pass "$name (rc=$rc)"
    fi
}

mk_json "$WORK/arity.json" none none upheld true
assert_arity_error A1-zero-args
assert_arity_error A2-one-arg   "$WORK/arity.json"
# A3 is the migration case itself: the retired 3-argument form.
assert_arity_error A3-three-args "$WORK/arity.json" user-explicit severity:high

# A4 is the control: the correct arity must still classify at exit 0, or A1-A3 would
# pass against a script that rejects everything.
run_gate "$WORK/arity.json" severity:low
if [ "$CONFIRM" = "<missing>" ]; then
    fail "A4-two-args-classifies" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
elif [ "$RC" -eq 0 ] && [ "$CONFIRM" = "no" ]; then
    pass "A4-two-args-classifies"
else
    fail "A4-two-args-classifies" "the correct 2-argument form must classify at exit 0 (rc=$RC, confirm=$CONFIRM)"
fi

echo ""
echo "=== robustness: a well-formed call always yields a verdict ==="
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "A5-unreadable-json-confirms" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "A6-missing-json-confirms" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "A7-unknown-severity-treated-as-not-high" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    printf '%s' '{ broken' > "$WORK/broken.json"
    run_gate "$WORK/broken.json" severity:high
    if [ "$RC" -eq 0 ] && [ "$CONFIRM" = "yes" ]; then
        pass "A5-unreadable-json-confirms"
    else
        fail "A5-unreadable-json-confirms" "an unparseable verdict file must fail-safe to confirm (rc=$RC, confirm=$CONFIRM)"
    fi

    run_gate "$WORK/definitely-not-here.json" severity:high
    if [ "$RC" -eq 0 ] && [ "$CONFIRM" = "yes" ]; then
        pass "A6-missing-json-confirms"
    else
        fail "A6-missing-json-confirms" "a missing verdict file must fail-safe to confirm (rc=$RC, confirm=$CONFIRM)"
    fi

    mk_json "$WORK/unk.json" none none upheld false
    run_gate "$WORK/unk.json" ""
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G3'; then
        pass "A7-unknown-severity-treated-as-not-high"
    else
        fail "A7-unknown-severity-treated-as-not-high" "an empty severity label is not 'high', so G3 must fire (confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "=== SKILL.md documents the gate and delegates the decision to the script ==="
if [ ! -f "$SKILL" ]; then
    fail "D1-skill-references-gate" "skills/issue-create/SKILL.md not found"
    fail "D2-skill-documents-G1-G4" "skills/issue-create/SKILL.md not found"
else
    if grep -qF 'eval-confirm-gate.sh' "$SKILL"; then
        pass "D1-skill-references-gate"
    else
        fail "D1-skill-references-gate" "RED-EXPECTED: SKILL.md does not call scripts/eval-confirm-gate.sh yet"
    fi
    MISSING=""
    for g in G1 G2 G3 G4; do grep -qF "$g" "$SKILL" || MISSING="$MISSING $g"; done
    if [ -z "$MISSING" ]; then
        pass "D2-skill-documents-G1-G4"
    else
        fail "D2-skill-documents-G1-G4" "RED-EXPECTED: gate condition(s) undocumented:$MISSING"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
