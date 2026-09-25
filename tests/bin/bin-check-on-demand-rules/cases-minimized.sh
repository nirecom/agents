# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh, bin/lib/check-on-demand-rules.js, hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, on-demand-rules, static-check, minimized-unconditional, violation-tokens, TL2, scope:common
#
# WHY (CPR-WPH): the MINIMIZED_UNCONDITIONAL half of #2037's declaration — the escape
# hatches, which stay unconditionally injected on purpose, so the only thing between them
# and the size they used to be is a declared byte ceiling plus a pointer at the procedure.

# The ON_DEMAND_READERS half is in cases-readers.sh; both files' helpers are in fixtures.sh.
# Assumes TOKEN, MARKER, BASE, node_path(), wr(), run_checker(), outfile_for(), rd_policy(),
# rd_min_base(), rd_expect(), pass(), fail() from the dispatcher and fixtures.sh.

echo ""
echo "=== minimized unconditional declarations (the four MINIMIZED_* tokens) ==="

# --- E: MINIMIZED_NOT_UNCONDITIONAL — the whole point of the minimized class is "stays
# unconditional on purpose". An entry that is not in EXPECTED_UNCONDITIONAL, or that
# carries the on-demand token, is claiming both at once. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-min-notlisted$RD_N"
rd_min_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md"]' \
    '["rules/min.md|skills/eho/SKILL.md"]' 1500
rd_expect "E1: a minimized rule absent from EXPECTED_UNCONDITIONAL is MINIMIZED_NOT_UNCONDITIONAL" "$d" MINIMIZED_NOT_UNCONDITIONAL yes "rules/min.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-min-ondemand$RD_N"
rd_min_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
    '["rules/od.md|skills/eho/SKILL.md"]' 1500
rd_expect "E2: a minimized rule that carries the on-demand token is MINIMIZED_NOT_UNCONDITIONAL" "$d" MINIMIZED_NOT_UNCONDITIONAL yes "rules/od.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-min-ok$RD_N"
rd_min_base "$d"
rd_expect "E3: a genuinely unconditional minimized rule raises nothing" "$d" MINIMIZED_NOT_UNCONDITIONAL no

# --- F: MINIMIZED_POINTER_MISSING — the declaration carries a repo-relative PATH (the
# existence check needs one), but the rule body should tell the reader to invoke a skill.
# Four cases fix that asymmetry: a skills/<n>/SKILL.md pointer is satisfied by either the
# `/<n>` slash form or the path; any other pointer requires the path, because relaxing it
# would leave a rule with no path at all and only the existence check still working. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-min-slash$RD_N"
rd_min_base "$d"
rd_expect "F1: skill pointer + body naming only /eho is satisfied" "$d" MINIMIZED_POINTER_MISSING no

RD_N=$((RD_N + 1)); d="$BASE/rd-min-path$RD_N"
rd_min_base "$d"
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `skills/eho/SKILL.md`.
EOF
rd_expect "F2: skill pointer + body naming only the pointer path is satisfied" "$d" MINIMIZED_POINTER_MISSING no

RD_N=$((RD_N + 1)); d="$BASE/rd-min-neither$RD_N"
rd_min_base "$d"
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Ask someone who knows.
EOF
rd_expect "F3: skill pointer + body naming neither form is MINIMIZED_POINTER_MISSING" "$d" MINIMIZED_POINTER_MISSING yes "rules/min.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-min-nonskill$RD_N"
rd_min_base "$d" "hooks/lib/ptr.js"
wr "$d/hooks/lib/ptr.js" <<'EOF'
"use strict";
module.exports = {};
EOF
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `/ptr`.
EOF
rd_expect "F4: a NON-skill pointer is not satisfied by a slash name — the path is required" "$d" MINIMIZED_POINTER_MISSING yes "rules/min.md"

# F5 is F4's positive control. Without it the pair reads "non-skill pointers always fire",
# which is also what a checker that simply rejected every non-skill pointer would produce,
# and the escape hatches that point at a doc or a code SSOT rather than a skill could
# never be declared at all.
RD_N=$((RD_N + 1)); d="$BASE/rd-min-nonskill-ok$RD_N"
rd_min_base "$d" "hooks/lib/ptr.js"
wr "$d/hooks/lib/ptr.js" <<'EOF'
"use strict";
module.exports = {};
EOF
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. The matrix lives in `hooks/lib/ptr.js`.
EOF
rd_expect "F5: a NON-skill pointer named by its path IS satisfied" "$d" MINIMIZED_POINTER_MISSING no

# --- G: MINIMIZED_POINTER_TARGET_MISSING — the body may name the pointer perfectly and
# still point at nothing. Kept separate from F on purpose: the fixture below satisfies F. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-min-ghostptr$RD_N"
rd_min_base "$d" "skills/ghostptr/SKILL.md"
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `/ghostptr`.
EOF
rd_expect "G1: a pointer with no file on disk is MINIMIZED_POINTER_TARGET_MISSING" "$d" MINIMIZED_POINTER_TARGET_MISSING yes "skills/ghostptr/SKILL.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-min-ptr-ok$RD_N"
rd_min_base "$d"
rd_expect "G2: a pointer whose target exists raises nothing" "$d" MINIMIZED_POINTER_TARGET_MISSING no

# --- H: MINIMIZED_RULE_TOO_LARGE — re-inflation is the failure mode this class exists to
# stop, and it happens one helpful paragraph at a time. The threshold is driven from the
# FIXTURE's MINIMIZED_MAX_BYTES so the case never depends on the size of a real rule. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-min-big$RD_N"
rd_min_base "$d" "skills/eho/SKILL.md" 40
rd_expect "H1: a minimized rule over MINIMIZED_MAX_BYTES is MINIMIZED_RULE_TOO_LARGE" "$d" MINIMIZED_RULE_TOO_LARGE yes "rules/min.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-min-small$RD_N"
rd_min_base "$d" "skills/eho/SKILL.md" 5000
rd_expect "H2: the same rule under a larger MINIMIZED_MAX_BYTES raises nothing" "$d" MINIMIZED_RULE_TOO_LARGE no

# --- H3: an unusable MINIMIZED_MAX_BYTES must fail CLOSED (exit 2, the same path a
# policy that cannot be read takes). Degrading to "no size limit" would silently retire
# the only check standing between a minimized rule and its former size.

# "Unusable" is a family, not one typo. Every row below reaches a naive
# `Number(x)` / `parseInt(x)` reader as something that is NOT a usable positive byte
# ceiling, and each fails in its own direction: some yield NaN, some yield a ceiling
# that rejects every possible rule, some silently truncate to a different number than
# the one written. The contract is one answer for the whole family — exit 2 — so that
# no spelling of a broken ceiling can quietly turn the size check off.
# Table columns: label|value
while IFS='|' read -r h3_label h3_value; do
    [ -z "$h3_label" ] && continue
    # A trailing blank field does not survive a heredoc row, so the blank case is spelled.
    [ "$h3_value" = "SPACE" ] && h3_value=" "
    RD_N=$((RD_N + 1)); d="$BASE/rd-min-bad$RD_N"
    rd_min_base "$d" "skills/eho/SKILL.md" "$h3_value"
    h3_rc="$(run_checker "$d" all)"
    if [ "$h3_rc" = "2" ]; then
        pass "H3 [$h3_label]: an unusable MINIMIZED_MAX_BYTES exits 2 (fail-closed), not 0"
    else
        fail "H3 [$h3_label]: want exit 2 for MINIMIZED_MAX_BYTES='$h3_value', got $h3_rc — a ceiling nobody can act on is being treated as a working one, so the size check is off with no signal; output: $(cat "$(outfile_for "$d")" 2>/dev/null | head -4 | tr '\n' ' ' | cut -c1-300)"
    fi
done <<'H3_EOF'
non-numeric|not-a-number
whitespace-only|SPACE
zero|0
negative|-1
fractional|1500.5
numeric-with-suffix|1500b
unsafe-integer|9007199254740993
H3_EOF

# --- H4/H5: the threshold as a BOUNDARY, not a magnitude. H1/H2 are 40-vs-5000 apart, so
# they hold for a comparison that is off by one in either direction, and off-by-one is the
# error that matters here: a ceiling meant to be inclusive but implemented as exclusive
# turns the agreed size into a failing size, and every minimized rule has to be rewritten
# to a number nobody chose. The convention pinned here is `size > max` fires — the rule may
# be exactly the ceiling. ---

# rd_min_sized <dir> <exact-bytes> — rewrites rules/min.md to EXACTLY <exact-bytes> bytes
# while keeping the trigger section and the `/eho` pointer, so only the size case can fire.
rd_min_sized() {
    local d="$1" want="$2" head pad n
    head='# X

## When to use

Last resort. Details: `/eho`.
'
    n=${#head}
    if [ "$want" -lt "$n" ]; then
        fail "rd_min_sized: asked for $want bytes but the smallest viable body is $n"
        return 1
    fi
    pad=""
    if [ "$((want - n))" -gt 0 ]; then
        pad="$(printf "%$((want - n))s" '' | tr ' ' 'x')"
    fi
    printf '%s%s' "$head" "$pad" > "$d/rules/min.md"
}

RD_N=$((RD_N + 1)); d="$BASE/rd-min-exact$RD_N"
rd_min_base "$d" "skills/eho/SKILL.md" 200
rd_min_sized "$d" 200
rd_expect "H4: a rule of EXACTLY MINIMIZED_MAX_BYTES is within budget, not over it" "$d" MINIMIZED_RULE_TOO_LARGE no

RD_N=$((RD_N + 1)); d="$BASE/rd-min-plusone$RD_N"
rd_min_base "$d" "skills/eho/SKILL.md" 200
rd_min_sized "$d" 201
rd_expect "H5: one byte over the ceiling fires" "$d" MINIMIZED_RULE_TOO_LARGE yes "rules/min.md"

# --- H6: the unit is BYTES. The rules corpus is not ASCII, and the checker is JS, where
# the obvious way to take a length (`String.length`) counts UTF-16 units — under which a
# Japanese rule could reach roughly three times its budget while every ASCII rule stayed
# honest. So the fixture below is placed BETWEEN the two measures: over the ceiling in
# bytes, exactly at it in string length (which H4 has already established passes).

# The ceiling is derived from the file, not hardcoded — a hand-counted number stops
# straddling the moment anyone edits the prose. `wc -m` is avoided for the same reason it
# would be wrong anywhere: under a C/POSIX locale it reports bytes, so the guard below
# would pass without the two measures ever disagreeing. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-min-multibyte$RD_N"
rd_min_base "$d" "skills/eho/SKILL.md" 1500
wr "$d/rules/min.md" <<'EOF'
# X

## When to use

`/eho`

最後の手段としてのみ用いる。詳細は移設先にある。手順はここには置かない。
EOF
rd_min_measure="$(node -e 'const b=require("fs").readFileSync(process.argv[1]);console.log(b.length+" "+b.toString("utf8").length)' "$(node_path "$d/rules/min.md")")"
rd_min_bytes="${rd_min_measure% *}"
rd_min_chars="${rd_min_measure#* }"
if [ "${rd_min_bytes:-0}" -le "${rd_min_chars:-0}" ]; then
    fail "H6-setup: the multibyte fixture does not straddle the two measures (bytes=$rd_min_bytes chars=$rd_min_chars) — the case cannot distinguish a byte ceiling from a character ceiling"
else
    pass "H6-setup: the fixture is $rd_min_bytes bytes but $rd_min_chars UTF-16 units, so the measures disagree across a ceiling of $rd_min_chars"
    rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
        '["rules/min.md|skills/eho/SKILL.md"]' "$rd_min_chars"
    rd_expect "H6: a multibyte rule over the ceiling in BYTES fires, though it is at the ceiling in characters" "$d" MINIMIZED_RULE_TOO_LARGE yes "rules/min.md"
fi

RD_N=$((RD_N + 1)); d="$BASE/rd-ptr-traverse$RD_N"
rd_min_base "$d" "../../../../etc/passwd"
wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `../../../../etc/passwd`.
EOF
rd_expect "J4: a minimized POINTER escaping the repo root is refused the same way a reader is" "$d" MINIMIZED_POINTER_TARGET_MISSING yes "rules/min.md"
