# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, on-demand-rules, skill-ownership, order-axis, false-positive, table-driven, TL2, scope:common

# WHY (CPR-WPH): a rule that stops being auto-injected only reaches the model because some skill
# Reads it. But WHEN the skill reads it decides whether reading it helped. `rules/ops.md` governs a
# destructive command; a SKILL.md that runs the command in Step 1 and Reads the rule in Step 4 has
# satisfied every check in this suite while the rule arrived after the only moment it could have
# changed the outcome.

# Position is a second axis, orthogonal to the reject-context axis in cases-reject-context.sh
# (WHERE the mention lives): here every mention is ordinary live prose and the ONLY difference
# between rows is whether the Read precedes or follows the governed action. The reporter
# (owners.js in the entry file) is a whole-file line scanner with no notion of document order.

# Same convention as cases-reject-context.sh: `ideal` is what an honest ownership claim would
# require, `pinned` is what the detector answers today, the assertion is on `pinned`, and every
# divergence prints a GAP line. The constraint here is tests-only, so the gap is RECORDED, not
# fixed — the pin makes the day someone closes it a visible, reviewed event (this file fails; the
# fix is to move `pinned` onto `ideal`). Assumes BASE, run_owners(), pass(), fail() from the entry.

echo ""
echo "=== order axis: a Read that follows the governed action is ownership on paper only ==="

# oa_fixture <variant> -> builds $BASE/oa-<variant> and prints its root.
# Every variant ships the SAME governed action and the SAME ordinary-prose Read sentence; only
# their relative order changes, so a difference in the answer could only come from position.
oa_fixture() {
    local variant="$1" d
    d="$BASE/oa-$variant"
    mkdir -p "$d/hooks/lib" "$d/skills/owner" "$d/agents" "$d/rules"
    cat > "$d/hooks/lib/rules-injection-policy.js" <<'OA_POLICY'
"use strict";
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_READERS = ["rules/owned.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
OA_POLICY
    printf '# the owned rule\n' > "$d/rules/owned.md"
    case "$variant" in
        read-before)
            # POSITIVE CONTROL: the honest shape — the rule arrives while it can still
            # change what Step 2 does.
            printf '# Owner skill\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n\n## Step 2\n\nRun the destructive step.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        read-after)
            # THE GAP CASE: identical sentences, reversed. The rule arrives only after the
            # governed action has already run.
            printf '# Owner skill\n\n## Step 1\n\nRun the destructive step.\n\n## Step 2\n\nRead `rules/owned.md` before continuing.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        read-last-line)
            # The extreme of read-after: the Read is the final line, after every step. Included
            # so the pin does not rest on one particular gap size.
            printf '# Owner skill\n\n## Step 1\n\nRun the destructive step.\n\n## Step 2\n\nReport the result.\n\n## Appendix\n\nRead `rules/owned.md` for background.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        action-only)
            # NEGATIVE CONTROL: the governed action with no Read anywhere, so the detector must
            # answer 0 for structural reasons.
            printf '# Owner skill\n\n## Step 1\n\nRun the destructive step.\n\n## Step 2\n\nReport the result.\n' \
                > "$d/skills/owner/SKILL.md" ;;
    esac
    printf '%s' "$d"
}

# oa_skill_read <variant> -> SKILL_READ as the reporter answers it for that fixture
oa_skill_read() {
    local d rep
    d="$(oa_fixture "$1")"
    rep="$(run_owners "$d" "$d/hooks/lib/rules-injection-policy.js")"
    printf '%s\n' "$rep" | grep '^RULE=' | tr ' ' '\n' | grep '^SKILL_READ=' | head -1 | cut -d= -f2-
}

# variant | ideal | pinned | description
OA_TABLE='read-before|1|1|a Read that precedes the governed action IS ownership (positive control)
read-after|0|1|a Read placed after the governed action cannot inform it
read-last-line|0|1|a Read in a trailing appendix is background, not a pre-condition
action-only|0|0|the governed action with no Read at all is not ownership (negative control)'

OA_ROWS=0; OA_BAD=0; OA_GAPS=0
while IFS='|' read -r oa_variant oa_ideal oa_pinned oa_desc; do
    [ -z "${oa_variant// /}" ] && continue
    OA_ROWS=$((OA_ROWS + 1))
    oa_got="$(oa_skill_read "$oa_variant")"
    if [ "$oa_got" != "$oa_pinned" ]; then
        OA_BAD=$((OA_BAD + 1))
        if [ "$oa_got" = "$oa_ideal" ]; then
            fail "O1 [$oa_variant]: the detector now answers SKILL_READ=$oa_got, which is the IDEAL — the order gap is closed, so move this row's pinned value from $oa_pinned to $oa_ideal ($oa_desc)"
        else
            fail "O1 [$oa_variant]: SKILL_READ=$oa_got, want the pinned $oa_pinned — $oa_desc"
        fi
        continue
    fi
    if [ "$oa_pinned" != "$oa_ideal" ]; then
        OA_GAPS=$((OA_GAPS + 1))
        echo "  GAP: [$oa_variant] SKILL_READ=$oa_got but the Read cannot have informed the governed action — $oa_desc"
        pass "O1 [$oa_variant]: current behaviour pinned at SKILL_READ=$oa_pinned (ideal $oa_ideal, gap recorded above)"
    else
        pass "O1 [$oa_variant]: SKILL_READ=$oa_got as required — $oa_desc"
    fi
done <<EOF
$OA_TABLE
EOF

if [ "$OA_ROWS" -ne 4 ]; then
    fail "O1-rows: want 4 order rows, ran $OA_ROWS — the table did not execute"
elif [ "$OA_BAD" -eq 0 ]; then
    pass "O1-rows: all 4 order rows answered as pinned ($OA_GAPS still-open detector gap(s))"
fi

# --- O2-live: the table must be able to separate its rows. If the positive and the negative
# control ever answer the SAME value the whole order axis is noise — a constant detector
# records nothing when pinned. ---
OA_POS="$(oa_skill_read read-before)"
OA_NEG="$(oa_skill_read action-only)"
if [ "$OA_POS" = "1" ] && [ "$OA_NEG" = "0" ]; then
    pass "O2-live: the controls disagree (read-before=$OA_POS, action-only=$OA_NEG) — the order rows measure the document, not a constant"
else
    fail "O2-live: the controls answered read-before=$OA_POS and action-only=$OA_NEG — the detector is not discriminating, so the pinned rows above mean nothing"
fi

# --- O3-blind: the direct statement of the gap. read-before and read-after carry the same two
# blocks in opposite order, so answering the same for both is proof of order-blindness.
# Asserting the EQUALITY names the missing capability instead of recording two numbers. ---
OA_BEFORE="$(oa_skill_read read-before)"
OA_AFTER="$(oa_skill_read read-after)"
if [ "$OA_BEFORE" = "$OA_AFTER" ] && [ "$OA_BEFORE" = "1" ]; then
    echo "  GAP: ownership is position-blind — swapping the Read and the governed action does not change SKILL_READ ($OA_BEFORE)"
    pass "O3-blind: the reporter answers SKILL_READ=$OA_BEFORE for both orders — order is NOT checked today, recorded as an open gap"
elif [ "$OA_BEFORE" = "1" ] && [ "$OA_AFTER" = "0" ]; then
    fail "O3-blind: the reporter now separates the orders (before=$OA_BEFORE, after=$OA_AFTER) — the order gap is closed; update the pinned column of OA_TABLE and this case"
else
    fail "O3-blind: unexpected answers (before=$OA_BEFORE, after=$OA_AFTER) — neither the pinned order-blind behaviour nor a clean order check"
fi

# --- O4-scope: bound the blast radius of the recorded gap. As with the reject-context gap, this
# one must OVER-count ownership and never hide a genuine reader — otherwise "order is unchecked"
# could equally mean "order is checked and the genuine reader was dropped". ---
d_oa="$(oa_fixture read-after)"
mkdir -p "$d_oa/skills/proper"
printf '# Proper owner\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n\n## Step 2\n\nRun the destructive step.\n' \
    > "$d_oa/skills/proper/SKILL.md"
OA_BOTH="$(run_owners "$d_oa" "$d_oa/hooks/lib/rules-injection-policy.js" \
    | grep '^RULE=' | tr ' ' '\n' | grep '^SKILL_READ=' | head -1 | cut -d= -f2-)"
if [ "$OA_BOTH" = "2" ]; then
    pass "O4-scope: the mis-ordered skill adds a spurious owner (SKILL_READ=2) beside the correctly-ordered one — the order gap over-counts ownership, it never hides a real reader"
elif [ "$OA_BOTH" = "1" ]; then
    fail "O4-scope: SKILL_READ=1 — the order gap recorded above no longer matches this shape; re-derive the pinned column before trusting it"
else
    fail "O4-scope: want SKILL_READ=2 (correctly-ordered owner + mis-ordered one), got '$OA_BOTH'"
fi
