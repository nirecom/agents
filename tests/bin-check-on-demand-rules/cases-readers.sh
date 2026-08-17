# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh, bin/lib/check-on-demand-rules.js, hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, on-demand-rules, static-check, readers, violation-tokens, TL2, scope:common
#
# WHY (CPR-WPH): #2037 moves the "which skill must Read this rule" fact out of a hand-written test table and into the policy declaration (ON_DEMAND_READERS). That is only worth declaring if a static checker can say, by name, when a declaration has gone wrong — otherwise a forgotten reader is invisible until a live session runs without the rule.
# So each violation token gets a PAIR: a fixture that must produce the token BY NAME, and a near-identical fixture that must NOT. A one-sided check cannot distinguish "the checker detects this" from "the checker rejects everything".
# The MINIMIZED_* half of the same declaration work is in cases-minimized.sh; the helpers both files use are in fixtures.sh.
# Assumes TOKEN, MARKER, BASE, CHECKER, node_path(), wr(), mk_repo(), run_checker(), outfile_for(), rd_policy(), rd_base(), rd_min_base(), rd_expect(), pass(), fail() from the dispatcher and fixtures.sh.

echo ""
echo "=== ON_DEMAND_READERS declarations (#2037 reader-side violation tokens) ==="

RD_N=0

# --- RD0: the new declaration shape is understood at all. Every "must NOT fire" case
# below would pass vacuously against a checker that cannot read ON_DEMAND_READERS, so the
# baseline tree is required to come back completely clean first. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-base$RD_N"
rd_base "$d"
rd0_rc="$(run_checker "$d" all)"
if [ "$rd0_rc" = "0" ]; then
    pass "RD0: a tree declaring ON_DEMAND_READERS (no ON_DEMAND_FILES) is accepted as clean"
else
    fail "RD0: the baseline ON_DEMAND_READERS tree is not clean (rc=$rd0_rc) — every 'token absent' case below would be vacuous; output: $(cat "$(outfile_for "$d")" 2>/dev/null | head -6 | tr '\n' ' ' | cut -c1-400)"
fi

# --- A: MALFORMED_READER_ROW — a row with no separator, or with zero readers, is a
# declaration that never said who owns the rule. It must not read as well-formed. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-mal-nosep$RD_N"
rd_base "$d"; rd_policy "$d" '["rules/od.md"]' '["rules/plain.md"]'
rd_expect "A1: a reader row with no '|' separator is MALFORMED_READER_ROW" "$d" MALFORMED_READER_ROW yes "rules/od.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-mal-empty$RD_N"
rd_base "$d"; rd_policy "$d" '["rules/od.md|"]' '["rules/plain.md"]'
rd_expect "A2: a reader row with a separator but zero readers is MALFORMED_READER_ROW" "$d" MALFORMED_READER_ROW yes "rules/od.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-mal-ok$RD_N"
rd_base "$d"
rd_expect "A3: a well-formed reader row does not raise MALFORMED_READER_ROW" "$d" MALFORMED_READER_ROW no

# --- B: READER_TARGET_MISSING — a declared reader that does not exist on disk. No skip
# condition: the reader's existence is internal consistency of the declaration, so it
# holds for any root, which is why every fixture here has to create the skill file. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-ghost$RD_N"
rd_base "$d"; rd_policy "$d" '["rules/od.md|skills/ghost/SKILL.md"]' '["rules/plain.md"]'
rd_expect "B1: a declared reader with no file on disk is READER_TARGET_MISSING" "$d" READER_TARGET_MISSING yes "skills/ghost/SKILL.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-ghost-ok$RD_N"
rd_base "$d"
rd_expect "B2: a declared reader that exists does not raise READER_TARGET_MISSING" "$d" READER_TARGET_MISSING no

# --- C: DUPLICATE_POLICY_ENTRY — the two lists answer opposite questions ("read on
# demand" vs "always injected"), so a rule in both makes the tree comparison in P5/P6
# unsatisfiable and hides which answer was intended. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-dup$RD_N"
rd_base "$d"; rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/od.md"]'
rd_expect "C1: a rule in both ON_DEMAND_READERS and EXPECTED_UNCONDITIONAL is DUPLICATE_POLICY_ENTRY" "$d" DUPLICATE_POLICY_ENTRY yes "rules/od.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-dup-ok$RD_N"
rd_base "$d"
rd_expect "C2: disjoint lists do not raise DUPLICATE_POLICY_ENTRY" "$d" DUPLICATE_POLICY_ENTRY no

# --- D: MISSING_ONDEMAND_POINTER — three cases pin the SKIP boundary as a declaration.
# A de-injected rule reaches the model only if CLAUDE.md still points at it, but CLAUDE.md
# is not guaranteed to exist in an arbitrary checked root, so this one check (and only
# this one — reader existence above stays unconditional) is skipped when it is absent. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-ptr-noclaude$RD_N"
rd_base "$d"; rm -f "$d/CLAUDE.md"
rd_expect "D1: no CLAUDE.md in the tree -> the pointer check is skipped, not failed" "$d" MISSING_ONDEMAND_POINTER no

RD_N=$((RD_N + 1)); d="$BASE/rd-ptr-ok$RD_N"
rd_base "$d"
rd_expect "D2: CLAUDE.md naming the on-demand rule raises nothing" "$d" MISSING_ONDEMAND_POINTER no

RD_N=$((RD_N + 1)); d="$BASE/rd-ptr-missing$RD_N"
rd_base "$d"
wr "$d/CLAUDE.md" <<'EOF'
# Project instructions

- Nothing here points at the de-injected rule.
EOF
rd_expect "D3: CLAUDE.md present but silent about the rule is MISSING_ONDEMAND_POINTER" "$d" MISSING_ONDEMAND_POINTER yes "rules/od.md"


# --- I: MULTI-ROW isolation. Every case above uses a one-row declaration, so all of them
# hold for a checker that only ever examines the first element. The real policy has eight
# reader rows and three minimized rows, and the row a contributor breaks is far more often
# a later one than the first. ---
RD_N=$((RD_N + 1)); d="$BASE/rd-multi-later$RD_N"
rd_base "$d"
wr "$d/rules/od2.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# Second on demand rule
EOF
wr "$d/rules/od3.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# Third on demand rule
EOF
wr "$d/skills/owner3/SKILL.md" <<'EOF'
# Owner 3

Read `rules/od3.md` before continuing.
EOF
wr "$d/CLAUDE.md" <<'EOF'
# Project instructions

- `rules/od.md`, `rules/od2.md` and `rules/od3.md` are not auto-injected — Read them first.
EOF
# Row 1 and row 3 are well-formed; row 2 names a reader that does not exist.
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md","rules/od2.md|skills/ghost2/SKILL.md","rules/od3.md|skills/owner3/SKILL.md"]' '["rules/plain.md"]'
rd_expect "I1: a broken SECOND row is found and named, not masked by a well-formed first row" "$d" READER_TARGET_MISSING yes "rules/od2.md"

RD_N=$((RD_N + 1)); d="$BASE/rd-multi-first$RD_N"
rd_base "$d"
wr "$d/rules/od2.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# Second on demand rule
EOF
wr "$d/CLAUDE.md" <<'EOF'
# Project instructions

- `rules/od.md` and `rules/od2.md` are not auto-injected — Read them first.
EOF
# The mirror: a broken FIRST row must not stop the scan before the valid rows behind it.
rd_policy "$d" '["rules/od.md|skills/ghost1/SKILL.md","rules/od2.md|skills/owner/SKILL.md"]' '["rules/plain.md"]'
RD_I2_RC="$(run_checker "$d" all)"
RD_I2_OUT="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if ! printf '%s\n' "$RD_I2_OUT" | grep -q '^READER_TARGET_MISSING:.*rules/od\.md'; then
    fail "I2: the broken first row was not reported (rc=$RD_I2_RC); output: $(printf '%s' "$RD_I2_OUT" | head -6 | tr '\n' ' ' | cut -c1-400)"
elif printf '%s\n' "$RD_I2_OUT" | grep -q 'rules/od2.md'; then
    fail "I2: the valid second row was also flagged — a single bad row must not condemn the rest of the declaration; output: $(printf '%s' "$RD_I2_OUT" | head -6 | tr '\n' ' ' | cut -c1-400)"
else
    pass "I2: a broken FIRST row is reported without dragging the valid rows behind it down with it"
fi

# --- J: the declaration is contributor-editable DATA, and its string VALUES get the same
# distrust the module body already gets in P11/P12. A reader or pointer is turned into a
# filesystem path by the checker, so a value that escapes the repo root or carries shell
# syntax must be refused as a path — never resolved outside the tree, never executed. ---

# The escape targets below are REAL, EXISTING files placed outside the fixture root.
# A traversal case whose target does not exist proves nothing: it would pass on a checker
# that happily resolves outside the tree, merely because the resolution found nothing.
# With the target present, the only way to reach READER_TARGET_MISSING is to refuse the
# path — resolving it would find a file and report ownership that the tree does not have.
RD_N=$((RD_N + 1)); d="$BASE/rd-traverse$RD_N"
rd_base "$d"
mkdir -p "$BASE/rd-outside$RD_N/skills/escapee"
printf '# escapee\n' > "$BASE/rd-outside$RD_N/skills/escapee/SKILL.md"
if [ ! -f "$BASE/rd-outside$RD_N/skills/escapee/SKILL.md" ]; then
    fail "J1-setup: the out-of-root escape target was not created, so J1 would pass vacuously"
else
    pass "J1-setup: the escape target exists outside the fixture root"
    rd_policy "$d" "[\"rules/od.md|../rd-outside$RD_N/skills/escapee/SKILL.md\"]" '["rules/plain.md"]'
    rd_expect "J1: a reader path escaping the repo root is refused even though the escaped-to file EXISTS" "$d" READER_TARGET_MISSING yes "rules/od.md"
fi

RD_N=$((RD_N + 1)); d="$BASE/rd-abs$RD_N"
rd_base "$d"
mkdir -p "$BASE/rd-abs-outside$RD_N/skills/escapee"
printf '# escapee\n' > "$BASE/rd-abs-outside$RD_N/skills/escapee/SKILL.md"
RD_J2_ABS="$(node_path "$BASE/rd-abs-outside$RD_N/skills/escapee/SKILL.md")"
if [ ! -f "$BASE/rd-abs-outside$RD_N/skills/escapee/SKILL.md" ]; then
    fail "J2-setup: the absolute escape target was not created, so J2 would pass vacuously"
else
    pass "J2-setup: the absolute escape target exists ($RD_J2_ABS)"
    rd_policy "$d" "[\"rules/od.md|$RD_J2_ABS\"]" '["rules/plain.md"]'
    rd_expect "J2: an ABSOLUTE reader path is refused even though it points at an EXISTING file — readers are repo-relative by contract" "$d" READER_TARGET_MISSING yes "rules/od.md"
fi

RD_N=$((RD_N + 1)); d="$BASE/rd-shellmeta$RD_N"
rd_base "$d"
RD_J3_CANARY="$d/VALUE-EXECUTED.txt"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md; touch VALUE-EXECUTED.txt"]' '["rules/plain.md"]'
RD_J3_RC="$(run_checker "$d" all)"
if [ -e "$RD_J3_CANARY" ]; then
    fail "J3: a declaration VALUE was executed as shell (canary written) — the policy file is contributor-editable, so this is arbitrary command execution on every pre-commit run"
elif [ "$RD_J3_RC" = "0" ]; then
    fail "J3: no canary, but the checker accepted 'skills/owner/SKILL.md; touch ...' as a valid reader path (rc=0) — the value is neither executed nor validated, so a typo of this shape reads as ownership that does not exist"
else
    pass "J3: a reader value carrying shell syntax is treated as a (nonexistent) path, not executed (rc=$RD_J3_RC)"
fi
