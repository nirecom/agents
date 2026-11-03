#!/usr/bin/env bash
# tests/skills/feat-1763-confirm-gate-matrix.sh
# Tests: skills/issue-create/scripts/eval-confirm-gate.sh, skills/issue-create/SKILL.md
# Tags: issue-create, confirm-gate, truth-table, worth-filing, table-driven, scope:issue-specific, pwsh-not-required, TL2, verdict-disputed, issue-1926, issue-2225
# TL3 gap: the skill actually raising AskUserQuestion when the script says "confirm: yes".
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
set -u

# Gate = OR of G1 (verdict touches existing issues), G2 (review disputed or survey != final),
# G3 (artifact missing/unparseable), G4 (status not upheld|disputed). #1926 retired G5 and
# moved worth_filing to an info line; the contract lives in SKILL.md "Phase 3" (SSOT).

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/eval-confirm-gate.sh"
SKILL="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/SKILL.md"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

GATE_PRESENT=no; [ -f "$GATE" ] && GATE_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mk_json <file> <final-verdict> <survey-verdict> <review-status> <worth-filing-json|__OMIT__>
# Shape is the review `--out` artifact; no proposal and no candidate bodies — the gate needs neither.
mk_json() {
    V="$2" SV="$3" RST="$4" WF="$5" node -e "
const fs=require('fs');
// same_fix is set only to keep the fixture schema-3 well-formed; the gate never reads it.
const SF = v => v === 'reopen';
const review = { status: process.env.RST, verdict: process.env.V, target: null,
                 children: [], related: [], reason: 'r', detail: '',
                 same_fix: SF(process.env.V) };
if (process.env.WF !== '__OMIT__') review.worth_filing = JSON.parse(process.env.WF);
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  verdict: process.env.V, same_fix: SF(process.env.V), target: null, children: [], related: [], reason: 'r',
  survey: { verdict: process.env.SV, same_fix: SF(process.env.SV), target: null, children: [], related: [], reason: 's' },
  review,
  candidates: [{ number: 1, title: 't', state: 'open' }]
}, null, 2));" "$1"
}

# run_gate <json> → sets CONFIRM / REASONS / WORTH / RC (confirm and reasons read from lines 1 and 2)
run_gate() {
    if [ "$GATE_PRESENT" != "yes" ]; then CONFIRM="<missing>"; REASONS="<missing>"; WORTH=""; RC=127; return; fi
    local out
    out=$("$RWT" 20 bash "$GATE" "$1" 2>"$WORK/gate-stderr.txt")
    RC=$?
    CONFIRM=$(printf '%s\n' "$out" | sed -n '1s/^confirm: *//p' | tr -d '[:space:]')
    REASONS=$(printf '%s\n' "$out" | sed -n '2s/^reasons: *//p' | tr -d '[:space:]')
    WORTH=$(printf '%s\n' "$out" | sed -n 's/^worth_filing: *//p' | head -n 1 | tr -d '[:space:]')
}

# assert_row <name> <verdict> <survey> <review-status> <worth-filing> <want-confirm> <want-reasons>
assert_row() {
    local name="$1" want_c="$6" want_r="$7"
    local jf="$WORK/$name.json"
    mk_json "$jf" "$2" "$3" "$4" "$5"
    run_gate "$jf"
    if [ "$CONFIRM" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: skills/issue-create/scripts/eval-confirm-gate.sh not yet created"
        return
    fi
    if [ "$RC" -ne 0 ]; then
        fail "$name" "want exit 0 (a well-formed 1-argument call always classifies), got $RC: $(head -n 1 "$WORK/gate-stderr.txt" 2>/dev/null)"
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

echo "=== truth table: verdict | survey | review_result | worth_filing ==="
# name                         verdict      survey       review    worth  confirm reasons
assert_row T01-none-clean      none         none         upheld    true   no      ""
assert_row T02-sibling-clean   sibling      sibling      upheld    true   no      ""

echo ""
echo "--- G1: verdicts that touch existing issues always confirm ---"
# sub-of / bulk-sub-of can reopen every closed ancestor of the parent chain, so they are G1 too (CPR-ORTH).
assert_row T04-reopen          reopen       reopen       upheld    true   yes     "G1"
assert_row T05-make-parent     make-parent  make-parent  upheld    true   yes     "G1"
assert_row T03-subof-clean     sub-of       sub-of       upheld    true   yes     "G1"
assert_row T19-bulk-subof      bulk-sub-of  bulk-sub-of  upheld    true   yes     "G1"

echo ""
echo "--- G2: the reviewer disagreed with the survey (#2225) ---"
# A disputed review keeps the survey's verdict at top level (survey == final), so T06 proves
# the status alone fires G2; T06b keeps the survey-vs-final arm alive.
assert_row T06-disputed        sibling      sibling      disputed  true   yes     "G2"
assert_row T06b-survey-differs sibling      none         upheld    true   yes     "G2"
assert_row T07-disputed-subof  sub-of       sub-of       disputed  true   yes     "G1,G2"

echo ""
echo "--- worth_filing is informational: it never fires a reason (#1926) ---"
assert_row T08-notworth        none         none         upheld    false  no      ""
assert_row T10-worth-null      none         none         upheld    null   no      ""
assert_row T11-worth-true      none         none         upheld    true   no      ""

echo ""
echo "--- G4: an unverified verdict always confirms ---"
assert_row T12-review-invalid  none         none         invalid   true   yes     "G4"
assert_row T13-review-skipped  none         none         skipped   true   yes     "G4"
assert_row T22-skipped-null    none         none         skipped   null   yes     "G4"
# `replaced` is no longer a status the reviewer leaves behind (#2225), so it reads as unverified.
assert_row T26-replaced-retired sibling     sibling      replaced  true   yes     "G4"

# T20/T21 — the no-Node degraded path copies the survey artifact, so no `review` object (or no
# status) reaches the gate. G4 as an allowlist reads that the same way it reads `invalid`.
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "T20-no-review-object-fires-G4" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "T21-review-without-status-fires-G4" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  proposal: { title: 't', background: 'b', changes: 'c' },
  verdict: 'none', same_fix: false, target: null, children: [], related: [], reason: 'r',
  candidates: [{ number: 1, title: 't', state: 'open', body: 'b1', labels: [] }]
}, null, 2));" "$WORK/nonode.json"
    run_gate "$WORK/nonode.json"
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "T20-no-review-object-fires-G4"
    else
        fail "T20-no-review-object-fires-G4" "an artifact with no review object means no review happened (confirm=$CONFIRM, reasons=$REASONS)"
    fi

    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  verdict: 'none', same_fix: false, target: null, children: [], related: [], reason: 'r',
  survey: { verdict: 'none', target: null, children: [], related: [], reason: 's' },
  review: { detail: 'partially written', verdict: null, target: null, worth_filing: true },
  candidates: [{ number: 1, title: 't', state: 'open' }]
}, null, 2));" "$WORK/nostatus.json"
    run_gate "$WORK/nostatus.json"
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "T21-review-without-status-fires-G4"
    else
        fail "T21-review-without-status-fires-G4" "a review object without a status is not a completed review (confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "--- OR semantics: overlapping conditions accumulate reasons ---"
assert_row T14-G1-G2           reopen       none         disputed  true   yes     "G1,G2"
assert_row T15-G1-notworth     make-parent  make-parent  upheld    false  yes     "G1"
assert_row T16-G4-notworth     none         none         skipped   false  yes     "G4"
assert_row T17-all-row-gates   reopen       none         invalid   false  yes     "G1,G2,G4"
assert_row T18-G1-G4           reopen       reopen       skipped   false  yes     "G1,G4"

echo ""
echo "=== worth_filing info line: only boolean true reads as true ==="
# A model writes the value and a shell reads it; either can turn a boolean into a string.
# The info line must not dress a lost answer up as an affirmation, and none may fire a reason.
assert_worth() {  # <name> <worth-filing-json|__OMIT__> <want-info>
    local name="$1" jf="$WORK/wf-$1.json"
    mk_json "$jf" none none upheld "$2"
    run_gate "$jf"
    if [ "$CONFIRM" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: skills/issue-create/scripts/eval-confirm-gate.sh not yet created"
    elif [ "$RC" -eq 0 ] && [ "$CONFIRM|$REASONS|$WORTH" = "no||$3" ]; then
        pass "$name"
    else
        fail "$name" "want rc=0 confirm=no reasons= worth_filing=$3 (rc=$RC confirm=$CONFIRM reasons=$REASONS worth=$WORTH)"
    fi
}

assert_worth P1-worth-filing-omitted   __OMIT__         unknown
assert_worth P2-worth-filing-null      null             unknown
assert_worth P3-worth-filing-string    '"true"'         unknown
assert_worth P4-worth-filing-number    1                unknown
assert_worth P5-worth-filing-empty-str '""'             unknown
assert_worth P6-worth-filing-space-str '"  "'           unknown
assert_worth P7-worth-filing-object    '{"value":true}' unknown
assert_worth P8-worth-filing-real-true true             true
assert_worth P9-worth-filing-false     false            false

echo ""
echo "=== A: argument arity is enforced, not silently reinterpreted ==="
# #1926 dropped the severity argument; an un-migrated 2-argument caller must fail loudly.
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
assert_arity_error A2-two-args   "$WORK/arity.json" severity:high
assert_arity_error A3-three-args "$WORK/arity.json" user-explicit severity:high

# A4 is the control: the correct arity must still classify, or A1-A3 would pass against a script that rejects everything.
run_gate "$WORK/arity.json"
if [ "$CONFIRM" = "<missing>" ]; then
    fail "A4-one-arg-classifies" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
elif [ "$RC" -eq 0 ] && [ "$CONFIRM" = "no" ]; then
    pass "A4-one-arg-classifies"
else
    fail "A4-one-arg-classifies" "the correct 1-argument form must classify at exit 0 (rc=$RC, confirm=$CONFIRM)"
fi

echo ""
echo "=== robustness: a missing or unreadable artifact fires G3 ==="
if [ "$GATE_PRESENT" != "yes" ]; then
    fail "A5-unreadable-json-confirms" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
    fail "A6-missing-json-confirms" "RED-EXPECTED: eval-confirm-gate.sh not yet created"
else
    printf '%s' '{ broken' > "$WORK/broken.json"
    run_gate "$WORK/broken.json"
    if [ "$RC" -eq 0 ] && [ "$CONFIRM|$REASONS" = "yes|G3" ]; then
        pass "A5-unreadable-json-confirms"
    else
        fail "A5-unreadable-json-confirms" "an unparseable verdict file must fail-safe to confirm via G3 (rc=$RC, confirm=$CONFIRM, reasons=$REASONS)"
    fi

    run_gate "$WORK/definitely-not-here.json"
    if [ "$RC" -eq 0 ] && [ "$CONFIRM|$REASONS" = "yes|G3" ]; then
        pass "A6-missing-json-confirms"
    else
        fail "A6-missing-json-confirms" "a missing verdict file must fail-safe to confirm via G3 (rc=$RC, confirm=$CONFIRM, reasons=$REASONS)"
    fi
fi

echo ""
echo "=== SKILL.md documents the gate and delegates the decision to the script ==="
if [ ! -f "$SKILL" ]; then
    fail "D1-skill-references-gate" "skills/issue-create/SKILL.md not found"
    fail "D2-skill-documents-G1-G4" "skills/issue-create/SKILL.md not found"
    fail "D3-skill-has-no-G5-bullet" "skills/issue-create/SKILL.md not found"
else
    if grep -qF 'eval-confirm-gate.sh' "$SKILL"; then
        pass "D1-skill-references-gate"
    else
        fail "D1-skill-references-gate" "SKILL.md does not call scripts/eval-confirm-gate.sh"
    fi
    MISSING=""
    for g in G1 G2 G3 G4; do grep -qE "^- $g " "$SKILL" || MISSING="$MISSING $g"; done
    if [ -z "$MISSING" ]; then
        pass "D2-skill-documents-G1-G4"
    else
        fail "D2-skill-documents-G1-G4" "gate condition bullet(s) missing:$MISSING"
    fi
    if ! grep -qE '^- G5 ' "$SKILL"; then
        pass "D3-skill-has-no-G5-bullet"
    else
        fail "D3-skill-has-no-G5-bullet" "SKILL.md still lists the retired G5 severity gate"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
