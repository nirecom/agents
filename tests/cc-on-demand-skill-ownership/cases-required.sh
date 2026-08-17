# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, rules/test.md, rules/docs.md, rules/github-issues.md
# Tags: rules-injection, on-demand-rules, skill-ownership, exact-mapping, mutation-probe, TL2, scope:common
#
# Exact rule -> consumer mapping (C1). The entry file's M1 check only proves "at least one SKILL.md reads this rule" (reachability, not ownership) — satisfied by ONE reader, even though rules/test.md covers the write/review/run triple and rules/github-issues.md covers eight issue/close-path skills.
# Under at-least-one, 7 of those 8 could silently drop their Read step and the suite would stay green — exactly the silent-loss this series exists to prevent. So the required set is named explicitly (detail plan S3-D table) and checked by EXACT SET EQUALITY.
# Each required reader is then proven individually load-bearing by removing it and showing the comparison fails BY NAME.
# This does NOT reopen the round-2 ruling that an agent-only reference is not SKILL.md ownership: compared against SKILL_BY (SKILL.md readers only); agents/ references counted separately by the reporter.
# Assumes REPORT, pass(), fail() from the entry file.

echo ""
echo "=== C1: exact rule -> required-consumer mapping ==="

# WHY the table is no longer written here (#2037): it used to be a hand-maintained copy of the detail plan's S3-D table, which made the rule -> reader fact live in two places — the test and the policy — and only the test could be updated without anyone noticing (CPR-SSOT). ON_DEMAND_READERS now carries that fact as declaration data, so the table is DERIVED from it and this file only checks the tree against it.
# Which skills belong in a row is therefore reviewed on the declaration, not here. The one property the derivation must never lose is non-emptiness: a policy that parsed to zero rows would make N1/N2 pass by iterating nothing, so N0a-N0d below fail loudly before any comparison runs.
# The policy is read as TEXT via rules-policy-reader.js — never require()d — for the same reason its other consumers do: a checked-out branch must not be able to run code by being read.

cat > "$BASE/readers-table.js" <<'READERS_TABLE_EOF'
"use strict";
const fs = require("fs");
const R = require(process.argv[2]);
const src = fs.readFileSync(process.argv[3], "utf8");
if (typeof R.readPairArrayConst !== "function") {
    console.log("HAVE=no");
    console.log("MALFORMED=-1");
    process.exit(0);
}
console.log("HAVE=yes");
const rows = R.readPairArrayConst(src, "ON_DEMAND_READERS") || [];
let malformed = 0;
for (const row of rows) {
    if (row.values === null) { malformed += 1; console.log("MALFORMED_ROW=" + row.key); continue; }
    console.log("TROW|" + row.key + "|" + row.values.join(","));
}
console.log("MALFORMED=" + malformed);
READERS_TABLE_EOF

RT_REPORT="$( cd "$BASE" && node "$(node_path "$BASE/readers-table.js")" "$(node_path "$READER")" "$(node_path "$POLICY")" 2>&1 )"
RT_HAVE="$(printf '%s\n' "$RT_REPORT" | grep '^HAVE=' | head -1 | cut -d= -f2-)"
RT_MALFORMED="$(printf '%s\n' "$RT_REPORT" | grep '^MALFORMED=' | head -1 | cut -d= -f2-)"

# rule | comma-separated SKILL.md paths that MUST carry an explicit Read step
REQUIRED_TABLE="$(printf '%s\n' "$RT_REPORT" | grep '^TROW|' | cut -d'|' -f2-)"
READER_ROWS="$(printf '%s' "$REQUIRED_TABLE" | grep -c '^[^ ]' || true)"
READER_TOTAL="$(printf '%s\n' "$REQUIRED_TABLE" | cut -d'|' -f2- | tr ',' '\n' | grep -c '^skills/' || true)"

# --- N0: the derivation itself. Every case after this one iterates REQUIRED_TABLE, so an
# empty or unparseable declaration would turn the whole group green by doing nothing. ---
if [ "$RT_HAVE" = "yes" ]; then
    pass "N0a: the policy reader exposes readPairArrayConst, so the required mapping can be derived at all"
else
    fail "N0a: readPairArrayConst is not available — the rule -> reader mapping cannot be derived from ON_DEMAND_READERS; harness said: $(printf '%s' "$RT_REPORT" | tr '\n' ' ' | cut -c1-300)"
fi

if [ "${READER_ROWS:-0}" -ge 1 ]; then
    pass "N0b: ON_DEMAND_READERS yielded $READER_ROWS rule row(s) — N1/N2 have something to compare"
else
    fail "N0b: ON_DEMAND_READERS yielded 0 rule rows — N1, N2 and the R group would all pass vacuously; harness said: $(printf '%s' "$RT_REPORT" | tr '\n' ' ' | cut -c1-300)"
fi

if [ "${READER_TOTAL:-0}" -ge 1 ]; then
    pass "N0c: the derived rows name $READER_TOTAL required SKILL.md reader(s) in total"
else
    fail "N0c: the derived rows name zero required readers — every row declared a rule with nobody obliged to Read it"
fi

if [ "$RT_MALFORMED" = "0" ]; then
    pass "N0d: no ON_DEMAND_READERS row is malformed (every row carries the '|' separator)"
else
    fail "N0d: $RT_MALFORMED malformed ON_DEMAND_READERS row(s) — a row with no separator declares no readers and would silently drop its rule: $(printf '%s\n' "$RT_REPORT" | grep '^MALFORMED_ROW=' | tr '\n' ' ')"
fi

# csv_sorted <csv> -> newline-separated, sorted, blanks dropped
csv_sorted() { printf '%s' "$1" | tr ',' '\n' | grep -v '^$' | sort; }

# req_verdict <want-csv> <got-csv> -> "OK" | "MISSING: a b" | "EXTRA: a b" | both
# The comparator is a separate function on purpose: N2 drives it directly with a
# mutated `got` set, which is what makes each required reader individually provable.
req_verdict() {
    local want="$1" got="$2" miss extra out=""
    miss="$(comm -23 <(csv_sorted "$want") <(csv_sorted "$got") | tr '\n' ' ')"
    extra="$(comm -13 <(csv_sorted "$want") <(csv_sorted "$got") | tr '\n' ' ')"
    [ -n "${miss// /}" ] && out="MISSING: ${miss% }"
    [ -n "${extra// /}" ] && out="${out:+$out; }EXTRA: ${extra% }"
    printf '%s' "${out:-OK}"
}

# skill_by_of <rule> -> the SKILL_BY csv the reporter produced for that rule over the
# REAL tree, or the literal NO_ROW when the rule is absent from ON_DEMAND_FILES.
skill_by_of() {
    local rule="$1" line
    line="$(printf '%s\n' "$REPORT" | grep "^RULE=$rule " | head -1)"
    if [ -z "$line" ]; then printf 'NO_ROW'; return; fi
    printf '%s' "$line" | tr ' ' '\n' | grep '^SKILL_BY=' | head -1 | cut -d= -f2-
}

# --- N1: the real tree matches the required mapping exactly. ---
N1_ROWS=0
while IFS='|' read -r rule want; do
    [ -z "${rule// /}" ] && continue
    N1_ROWS=$((N1_ROWS + 1))
    got="$(skill_by_of "$rule")"
    if [ "$got" = "NO_ROW" ]; then
        fail "N1 [$rule]: not listed in ON_DEMAND_FILES, so its required readers are unverified (detail plan S3-D)"
        continue
    fi
    [ "$got" = "-" ] && got=""
    v="$(req_verdict "$want" "$got")"
    if [ "$v" = "OK" ]; then
        pass "N1 [$rule]: read by exactly its $(csv_sorted "$want" | grep -c .) required SKILL.md consumer(s)"
    else
        # EXTRA is a failure too, not a courtesy: the mapping is the record of which
        # skills depend on the rule. A new reader is fine — it just has to be added to
        # the table above, so the dependency stays reviewable in one place (CPR-SSOT).
        fail "N1 [$rule]: consumer set differs from the S3-D table — $v"
    fi
done <<EOF
$REQUIRED_TABLE
EOF

if [ "$N1_ROWS" -ge 1 ] && [ "$N1_ROWS" -eq "${READER_ROWS:-0}" ]; then
    pass "N1-rows: every one of the $N1_ROWS declared ON_DEMAND_READERS rows was compared against the real tree"
else
    fail "N1-rows: the declaration carries ${READER_ROWS:-0} row(s) but the loop compared $N1_ROWS — a row was dropped between the harness and the comparison, or the declaration is empty"
fi

# --- N2: leave-one-out. For each required reader, feed the comparator the real
# required set with exactly that reader removed, and demand it reports the reader BY
# NAME. An assertion that fails without saying which skill lost its Read step sends the
# next maintainer looking through eight SKILL.md files by hand. ---
N2_TOTAL=0
N2_BAD=""
while IFS='|' read -r rule want; do
    [ -z "${rule// /}" ] && continue
    for victim in $(csv_sorted "$want"); do
        N2_TOTAL=$((N2_TOTAL + 1))
        mutated="$(csv_sorted "$want" | grep -vx "$victim" | tr '\n' ',')"
        v="$(req_verdict "$want" "${mutated%,}")"
        case "$v" in
            *"MISSING:"*"$victim"*) ;;
            *) N2_BAD="$N2_BAD [$rule -$victim -> '$v']" ;;
        esac
    done
done <<EOF
$REQUIRED_TABLE
EOF

if [ "$N2_TOTAL" -ge 1 ] && [ "$N2_TOTAL" -eq "${READER_TOTAL:-0}" ] && [ -z "$N2_BAD" ]; then
    pass "N2: each of the $N2_TOTAL declared readers is individually load-bearing — dropping any one is reported by name"
elif [ "$N2_TOTAL" -lt 1 ] || [ "$N2_TOTAL" -ne "${READER_TOTAL:-0}" ]; then
    fail "N2: the declaration names ${READER_TOTAL:-0} reader(s) but the leave-one-out loop enumerated $N2_TOTAL — with 0 the probe proves nothing, and a mismatch means readers were lost while splitting the rows"
else
    fail "N2: removing a required reader went unreported —$N2_BAD"
fi

# --- N3: the mirror image. An unlisted reader must surface as EXTRA, otherwise N1
# degenerates into the superset check it was written to replace. ---
N3="$(req_verdict "skills/a/SKILL.md,skills/b/SKILL.md" "skills/a/SKILL.md,skills/b/SKILL.md,skills/c/SKILL.md")"
case "$N3" in
    *"EXTRA:"*"skills/c/SKILL.md"*) pass "N3: a reader outside the table is reported as EXTRA by name" ;;
    *) fail "N3: an unlisted reader was accepted silently — got '$N3'" ;;
esac

# --- N4: the comparator must not call a wholly different set equal. This is the
# degenerate case that would make N1/N2 vacuous if comm were fed unsorted input. ---
N4="$(req_verdict "skills/a/SKILL.md" "skills/z/SKILL.md")"
case "$N4" in
    *"MISSING:"*"skills/a/SKILL.md"*"EXTRA:"*"skills/z/SKILL.md"*)
        pass "N4: a disjoint consumer set reports both the missing and the extra reader" ;;
    *) fail "N4: want both MISSING and EXTRA for a disjoint set, got '$N4'" ;;
esac

# --- N5: the settled end-state FLOOR, written as literals.
# WHY this exists next to a derived table: N1-N4 all take their `want` side from
# ON_DEMAND_READERS, so the declaration is both the question and the answer key. Delete a
# rule's row from the policy AND its Read step from the skill in the same commit and every
# case above still passes — nothing is left that remembers the pair was ever required.
# The floor is the memory. It names only the pairs #1651 and #2037 actually settled (never
# the whole table, which stays owned by the declaration per CPR-SSOT), and it compares the
# literal against the REAL TREE via skill_by_of — not against the declaration — so a
# both-sides deletion has nowhere to hide. A new consumer belongs in the declaration; a
# row belongs here only once the issue that settled it has shipped. ---

# The consumer lists below are HARD-CODED on purpose — a deliberate regression floor.
# Reading them out of ON_DEMAND_READERS instead would assert the declaration equals
# itself, which is exactly the false-green shape bin/check-false-green.sh exists to catch.
# github-issues.md / coding.md / ops.md carry their full declared reader sets because
# #2037 widened them: coding.md governs outbound text (issue, PR, commit, docs), and
# ops.md governs any destructive or system-state step, so a skill dropping its Read step
# is a real loss of governance, not a tidy-up.
N5_FLOOR='rules/test.md|skills/write-tests/SKILL.md,skills/review-tests/SKILL.md,skills/run-tests/SKILL.md
rules/docs.md|skills/update-docs/SKILL.md
rules/github-issues.md|skills/issue-create/SKILL.md,skills/issue-close-stage/SKILL.md,skills/issue-close-finalize/SKILL.md,skills/issue-reconcile/SKILL.md,skills/issue-close-migrated/SKILL.md,skills/clarify-intent/SKILL.md,skills/commit-push/SKILL.md,skills/worktree-end/SKILL.md,skills/workflow-init/SKILL.md,skills/sweep-issues/SKILL.md,skills/issue-setup/SKILL.md
rules/branch.md|skills/make-detail-plan/SKILL.md,skills/worktree-start/SKILL.md
rules/worktree.md|skills/make-detail-plan/SKILL.md,skills/worktree-start/SKILL.md
rules/mid-workflow-findings.md|skills/issue-create/SKILL.md,skills/worktree-end/SKILL.md
rules/coding.md|skills/write-code/SKILL.md,skills/issue-create/SKILL.md,skills/commit-push/SKILL.md,skills/update-docs/SKILL.md,skills/worktree-end/SKILL.md,skills/issue-close-stage/SKILL.md,skills/issue-close-finalize/SKILL.md
rules/ops.md|skills/worktree-end/SKILL.md,skills/write-code/SKILL.md,skills/worktree-start/SKILL.md'

# n5_check <rule> <consumer-csv> -> prints "OK" or the reason it failed, tree-first.
n5_check() {
    local rule="$1" want="$2" got missing=""
    got="$(skill_by_of "$rule")"
    [ "$got" = "NO_ROW" ] && { printf 'the rule is not on-demand at all (absent from ON_DEMAND_FILES)'; return; }
    [ "$got" = "-" ] && got=""
    for c in $(csv_sorted "$want"); do
        printf '%s\n' "$(csv_sorted "$got")" | grep -qx "$c" || missing="$missing $c"
    done
    if [ -n "${missing// /}" ]; then printf 'no Read step in:%s' "$missing"; else printf 'OK'; fi
}

N5_ROWS=0
while IFS='|' read -r rule want; do
    [ -z "${rule// /}" ] && continue
    N5_ROWS=$((N5_ROWS + 1))
    v="$(n5_check "$rule" "$want")"
    if [ "$v" = "OK" ]; then
        pass "N5 [$rule]: the settled consumers still Read it — the pair survives independently of what the policy declares"
    else
        fail "N5 [$rule]: $v — this pair was settled by #1651/#2037; removing it from ON_DEMAND_READERS does not retire the obligation, it only hides it from N1"
    fi
done <<EOF
$N5_FLOOR
EOF

N5_WANT=8
if [ "$N5_ROWS" -eq "$N5_WANT" ]; then
    pass "N5-rows: all $N5_WANT floor rows were checked"
else
    fail "N5-rows: the floor lists $N5_ROWS row(s), want $N5_WANT — rows were lost while splitting, or the floor was edited without updating the count that guards it"
fi

# Self-check: the floor must be able to fail. A comparator that returned OK for anything
# would make every row above meaningless.
N5_NEG="$(n5_check "rules/test.md" "skills/no-such-skill/SKILL.md")"
if [ "$N5_NEG" = "OK" ]; then
    fail "N5-neg: a consumer that does not exist was reported as satisfied — the floor comparison is vacuous"
else
    pass "N5-neg: a consumer absent from the tree is reported by name ($N5_NEG)"
fi

# --- R: the independent, tree-first mention axis. Split into a sibling file because
# this one crossed the 300-line WARN (rules/coding/file-split.md Pattern A); it is
# sourced from here rather than from the entry file so REQUIRED_TABLE and the helpers
# above stay in scope. ---
MENTION_CASES="$AGENTS_DIR/tests/cc-on-demand-skill-ownership/cases-mention-axis.sh"
if [ -f "$MENTION_CASES" ]; then
    # shellcheck source=/dev/null
    . "$MENTION_CASES"
else
    fail "IMPLEMENTATION MISSING: $MENTION_CASES (independent mention-axis cases)"
fi

