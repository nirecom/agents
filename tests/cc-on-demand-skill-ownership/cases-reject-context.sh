# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, rules/test.md, rules/docs.md, rules/github-issues.md
# Tags: rules-injection, on-demand-rules, skill-ownership, reject-context, false-positive, table-driven, TL2, scope:common

# Where a mention LIVES decides whether it's a promise or a description. The ownership detector is
# a line scanner: it looks for the rule path on a line and a `Read` verb within a couple of lines of
# it. Three contexts routinely put both next to each other while promising nothing: a fenced code block
# (documentation SHOWING the step, e.g. a skill that explains how other skills load rules), an HTML
# comment (a note to maintainers, invisible to the rendered document and the model), or a `#`-prefixed
# line (a markdown heading, or a shell comment inside an example). If any of those counts as ownership,
# M1 and the C1/R mappings can be satisfied by a skill that never actually reads the rule — a false
# green in exactly the direction this series exists to prevent.

# So the table below states, per context, what the detector WOULD have to answer for the ownership
# claim to be honest (`ideal`), and what it answers TODAY (`pinned`). The assertion is on `pinned`,
# and every row where the two differ prints an explicit GAP line naming the unclosed hole. That
# is deliberate: the constraint on this change is tests-only, so a detector gap is RECORDED
# here rather than fixed in the reporter, and the pin makes the day someone closes it a visible,
# reviewed event (this file fails, and the fix is to move `pinned` onto `ideal`). Assumes BASE,
# run_owners(), pass(), fail() from the entry file.

echo ""
echo "=== reject-context: where a mention lives decides whether it is ownership ==="

# rc_fixture <variant> -> builds $BASE/rc-<variant> and prints its root
rc_fixture() {
    local variant="$1" d
    d="$BASE/rc-$variant"
    mkdir -p "$d/hooks/lib" "$d/skills/owner" "$d/agents" "$d/rules"
    cat > "$d/hooks/lib/rules-injection-policy.js" <<'RC_POLICY'
"use strict";
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_READERS = ["rules/owned.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
RC_POLICY
    printf '# the owned rule\n' > "$d/rules/owned.md"
    case "$variant" in
        prose)
            # POSITIVE CONTROL: an ordinary instruction. This is what ownership looks
            # like, and it is what makes the rejected-context rows meaningful — without
            # it, "0 everywhere" would also satisfy the table.
            printf '# Owner skill\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        fenced)
            printf '# Owner skill\n\n## Step 1\n\nOther skills load their rules like this:\n\n```\nRead `rules/owned.md` first.\n```\n\nDo the work.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        html-comment)
            printf '# Owner skill\n\n## Step 1\n\n<!-- maintainer note: Read `rules/owned.md` if we ever need it here -->\n\nDo the work.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        hash-line)
            printf '# Owner skill\n\n# Read `rules/owned.md`\n\nDo the work.\n' \
                > "$d/skills/owner/SKILL.md" ;;
        absent)
            # NEGATIVE CONTROL: no mention at all, so the detector must answer 0 for
            # structural reasons. A table in which every row answers 1 would otherwise
            # be indistinguishable from a detector that always answers 1.
            printf '# Owner skill\n\n## Step 1\n\nDo the work.\n' \
                > "$d/skills/owner/SKILL.md" ;;
    esac
    printf '%s' "$d"
}

# rc_skill_read <variant> -> SKILL_READ as the reporter answers it for that fixture
rc_skill_read() {
    local d rep
    d="$(rc_fixture "$1")"
    rep="$(run_owners "$d" "$d/hooks/lib/rules-injection-policy.js")"
    printf '%s\n' "$rep" | grep '^RULE=' | tr ' ' '\n' | grep '^SKILL_READ=' | head -1 | cut -d= -f2-
}

# variant | ideal | pinned | description
RC_TABLE='prose|1|1|an ordinary Read instruction IS ownership (positive control)
fenced|0|1|a Read shown inside a fenced code block is documentation, not a step
html-comment|0|1|a Read inside an HTML comment is a maintainer note the model never executes
hash-line|0|1|a Read on a #-prefixed line is a heading or a shell comment, not a step
absent|0|0|no mention at all is not ownership (negative control)'

RC_ROWS=0; RC_BAD=0; RC_GAPS=0
while IFS='|' read -r rc_variant rc_ideal rc_pinned rc_desc; do
    [ -z "${rc_variant// /}" ] && continue
    RC_ROWS=$((RC_ROWS + 1))
    rc_got="$(rc_skill_read "$rc_variant")"
    if [ "$rc_got" != "$rc_pinned" ]; then
        RC_BAD=$((RC_BAD + 1))
        if [ "$rc_got" = "$rc_ideal" ]; then
            fail "C3 [$rc_variant]: the detector now answers SKILL_READ=$rc_got, which is the IDEAL — the gap is closed, so move this row's pinned value from $rc_pinned to $rc_ideal ($rc_desc)"
        else
            fail "C3 [$rc_variant]: SKILL_READ=$rc_got, want the pinned $rc_pinned — $rc_desc"
        fi
        continue
    fi
    if [ "$rc_pinned" != "$rc_ideal" ]; then
        RC_GAPS=$((RC_GAPS + 1))
        echo "  GAP: [$rc_variant] SKILL_READ=$rc_got but ownership here is not real — $rc_desc"
        pass "C3 [$rc_variant]: current behaviour pinned at SKILL_READ=$rc_pinned (ideal $rc_ideal, gap recorded above)"
    else
        pass "C3 [$rc_variant]: SKILL_READ=$rc_got as required — $rc_desc"
    fi
done <<EOF
$RC_TABLE
EOF

if [ "$RC_ROWS" -ne 5 ]; then
    fail "C3-rows: want 5 context rows, ran $RC_ROWS — the table did not execute"
elif [ "$RC_BAD" -eq 0 ]; then
    pass "C3-rows: all 5 context rows answered as pinned ($RC_GAPS still-open detector gap(s))"
fi

# --- C3-live: the table above must be able to separate its rows. If the positive and
# the negative control ever answer the SAME value, every reject-context row is noise:
# the detector would be a constant, and pinning a constant records nothing. ---
RC_POS="$(rc_skill_read prose)"
RC_NEG="$(rc_skill_read absent)"
if [ "$RC_POS" = "1" ] && [ "$RC_NEG" = "0" ]; then
    pass "C3-live: the controls disagree (prose=$RC_POS, absent=$RC_NEG) — the reject-context rows measure the context, not a constant"
else
    fail "C3-live: the controls answered prose=$RC_POS and absent=$RC_NEG — the detector is not discriminating, so the pinned rows above mean nothing"
fi

# --- C3-scope: the recorded gap is about ATTRIBUTION, not about the rule going
# unowned. A skill whose ONLY mention sits in a rejected context, with a genuine reader
# elsewhere in the tree, must still leave the genuine reader counted. This is what keeps
# the pin honest: the gap over-counts owners, it never under-counts them. ---
d_pos="$(rc_fixture prose)"
mkdir -p "$d_pos/skills/bystander"
printf '# Bystander\n\n## Step 1\n\nOther skills do this:\n\n```\nRead `rules/owned.md` first.\n```\n' \
    > "$d_pos/skills/bystander/SKILL.md"
RC_BOTH="$(run_owners "$d_pos" "$d_pos/hooks/lib/rules-injection-policy.js" \
    | grep '^RULE=' | tr ' ' '\n' | grep '^SKILL_READ=' | head -1 | cut -d= -f2-)"
if [ "$RC_BOTH" = "2" ]; then
    pass "C3-scope: a fenced mention adds a spurious owner (SKILL_READ=2) beside the genuine one — the gap over-counts ownership, it never hides a real reader"
elif [ "$RC_BOTH" = "1" ]; then
    fail "C3-scope: SKILL_READ=1 — the reject-context gap recorded above no longer matches this shape; re-derive the pinned column before trusting it"
else
    fail "C3-scope: want SKILL_READ=2 (genuine owner + fenced bystander), got '$RC_BOTH'"
fi
