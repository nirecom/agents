# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js, rules/handoff-emergency-flush.md
# Tags: rules-injection, policy, unconditional, handoff, regression-2218, table-driven, TL2, scope:issue-specific
#
# Issue #2218 Step 10/13 — the emergency-flush rule is an escape hatch of the same shape as
# rules/stop-guard-exemptions.md: a session about to lose its context must not have to earn the
# rule by matching a path glob, so it is registered UNCONDITIONAL (the 8th entry).
# Why by name and not by P5's set comparison: while the rule file does not exist, P5 compares two
# sets that agree vacuously about it, so nothing records that the registration was intended.
# Assumes AGENTS_DIR, READER, POLICY, pass(), fail(), node_path() come from the dispatcher.

echo ""
echo "=== issue #2218: the emergency-flush rule is registered unconditional ==="

FLUSH_RULE="rules/handoff-emergency-flush.md"

# Parse, don't evaluate (CPR-ORTH with P11/P12): the constant is recovered through the
# agents-owned reader, never by require()-ing the contributor-editable policy file.
cat > "$BASE/flush-registration.js" <<'FLUSH_REG_EOF'
"use strict";
// argv: <reader> <policy-path> <rule-path>
const fs = require("fs");
const R = require(process.argv[2]);
const eu = R.readStringArrayConst(fs.readFileSync(process.argv[3], "utf8"), "EXPECTED_UNCONDITIONAL");
if (eu === null) { console.log("UNREADABLE"); process.exit(0); }
console.log((eu.includes(process.argv[4]) ? "yes" : "no") + " count=" + eu.length);
FLUSH_REG_EOF

FLUSH_REG="$(node "$(node_path "$BASE/flush-registration.js")" "$(node_path "$READER")" \
    "$(node_path "$POLICY")" "$FLUSH_RULE" 2>&1)"
case "$FLUSH_REG" in
    yes*) pass "UF1: $FLUSH_RULE is registered in EXPECTED_UNCONDITIONAL ($FLUSH_REG)" ;;
    no*)  fail "UF1: $FLUSH_RULE is absent from EXPECTED_UNCONDITIONAL ($FLUSH_REG) — issue #2218 Step 10 adds it as the 8th unconditional rule; write_code has not run" ;;
    *)    fail "UF1: EXPECTED_UNCONDITIONAL could not be recovered from $POLICY — reader said '$FLUSH_REG'" ;;
esac

# The other half of the same registration. Split from F1 so a listed-but-absent entry and an
# entry that disables its own auto-injection are distinguishable; P5 would only say "the sets
# differ". `head -1` is the whole test: a frontmatter block can only open the file.
if [ ! -f "$AGENTS_DIR/$FLUSH_RULE" ]; then
    fail "UF2: $FLUSH_RULE does not exist — issue #2218 Step 14 authors it; write_code has not run"
elif head -1 "$AGENTS_DIR/$FLUSH_RULE" | grep -q '^---'; then
    fail "UF2: $FLUSH_RULE opens with a frontmatter block — an unconditional escape-hatch rule carries no paths: key at all"
else
    pass "UF2: $FLUSH_RULE exists and carries no frontmatter block, matching its unconditional registration"
fi

# UF3 — the other half of the same-shape claim, pinned the other way. Unlike
# stop-guard-exemptions/supervisor-reporting/workflow-off, detail.md's C5 fix
# directs only an EXPECTED_UNCONDITIONAL addition for this rule — it defines
# its own trigger-and-procedure content in full rather than deferring to a
# pointer file, so it must NOT also join MINIMIZED_UNCONDITIONAL (which would
# additionally cap it at MINIMIZED_MAX_BYTES). Read via readStringArrayConst,
# not require(), for the same reason UF1 does.
cat > "$BASE/flush-minimized.js" <<'FLUSH_MIN_EOF'
"use strict";
// argv: <reader> <policy-path> <rule-path>
const fs = require("fs");
const R = require(process.argv[2]);
const mu = R.readStringArrayConst(fs.readFileSync(process.argv[3], "utf8"), "MINIMIZED_UNCONDITIONAL");
if (mu === null) { console.log("UNREADABLE"); process.exit(0); }
const joined = mu.some((row) => row.split("|")[0] === process.argv[4]);
console.log((joined ? "yes" : "no") + " count=" + mu.length);
FLUSH_MIN_EOF

FLUSH_MIN="$(node "$(node_path "$BASE/flush-minimized.js")" "$(node_path "$READER")" \
    "$(node_path "$POLICY")" "$FLUSH_RULE" 2>&1)"
# Finding 7 (round 3): the prefix-only match let a truncated MINIMIZED_UNCONDITIONAL
# parse — the ']'-inside-element gap cases-minimized-decl.sh T1 documents — pass
# silently as "no count=0". Assert the count too, matching UF1's own count= check.
FLUSH_MIN_COUNT="$(printf '%s' "$FLUSH_MIN" | sed -n 's/^.*count=\([0-9]*\)$/\1/p')"
case "$FLUSH_MIN" in
    no*)
        if [ -z "$FLUSH_MIN_COUNT" ] || [ "$FLUSH_MIN_COUNT" -lt 3 ]; then
            fail "UF3: MINIMIZED_UNCONDITIONAL parse looks truncated ($FLUSH_MIN) — expected count>=3 (7 existing unconditional rules), got a count consistent with a ']'-inside-element parse gap"
        else
            pass "UF3: $FLUSH_RULE stays OUT of MINIMIZED_UNCONDITIONAL ($FLUSH_MIN) — it carries its own full procedure, not a pointer-deferred stub"
        fi
        ;;
    yes*) fail "UF3: $FLUSH_RULE was added to MINIMIZED_UNCONDITIONAL ($FLUSH_MIN) — detail.md's C5 fix only calls for EXPECTED_UNCONDITIONAL; a minimized entry would also need a documented MINIMIZED_MAX_BYTES budget, which was never planned" ;;
    *)    fail "UF3: MINIMIZED_UNCONDITIONAL could not be recovered from $POLICY — reader said '$FLUSH_MIN'" ;;
esac
unset FLUSH_MIN_COUNT

unset FLUSH_REG FLUSH_MIN
