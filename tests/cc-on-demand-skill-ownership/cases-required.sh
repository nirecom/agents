# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, rules/test.md, rules/docs.md, rules/github-issues.md
# Tags: rules-injection, on-demand-rules, skill-ownership, exact-mapping, mutation-probe, TL2, scope:common
#
# Exact rule -> consumer mapping (C1).
#
# M1 in the entry file asks "does at least one SKILL.md read this rule". That is a
# reachability check, not an ownership check, and it is satisfied by ONE reader. The
# rules being de-injected here are read by several skill families each: rules/test.md
# governs the write/review/run test triple, rules/github-issues.md governs eight issue
# and close-path skills. Under an at-least-one check, seven of those eight could drop
# their Read step and the suite would stay green — every one of those skills would then
# be running without the rule that used to arrive automatically, which is exactly the
# silent-loss this series exists to prevent.
#
# So the required set is named explicitly (detail plan S3-D table) and compared for
# EXACT SET EQUALITY, and each required reader is then shown to be individually
# load-bearing by removing it and proving the comparison fails BY NAME.
#
# This does NOT re-open the round-2 ruling that an agent-only reference is not SKILL.md
# ownership: the sets below are compared against SKILL_BY (SKILL.md readers only), and
# agents/ references remain counted separately by the reporter.
#
# Assumes REPORT, pass(), fail() from the entry file.

echo ""
echo "=== C1: exact rule -> required-consumer mapping ==="

# rule | comma-separated SKILL.md paths that MUST carry an explicit Read step
REQUIRED_TABLE='rules/test.md|skills/write-tests/SKILL.md,skills/review-tests/SKILL.md,skills/run-tests/SKILL.md
rules/docs.md|skills/update-docs/SKILL.md
rules/github-issues.md|skills/issue-create/SKILL.md,skills/issue-close-stage/SKILL.md,skills/issue-close-finalize/SKILL.md,skills/issue-reconcile/SKILL.md,skills/issue-close-migrated/SKILL.md,skills/clarify-intent/SKILL.md,skills/commit-push/SKILL.md,skills/worktree-end/SKILL.md,skills/workflow-init/SKILL.md,skills/sweep-issues/SKILL.md,skills/issue-setup/SKILL.md'

# The three readers added last (workflow-init, sweep-issues, issue-setup) each open an
# issue/label operation of their own, so each has to Read rules/github-issues.md rather
# than inherit it from whoever called them. skills/sweep-branches/SKILL.md is NOT here
# on purpose: it carries zero issue or label references, so requiring a Read step there
# would pin a dependency that does not exist.

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

if [ "$N1_ROWS" -eq 3 ]; then
    pass "N1-rows: all three de-injected rules have a required-consumer row"
else
    fail "N1-rows: want 3 required-consumer rows, parsed $N1_ROWS — the table itself is malformed"
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

if [ "$N2_TOTAL" -eq 15 ] && [ -z "$N2_BAD" ]; then
    pass "N2: each of the 15 required readers is individually load-bearing — dropping any one is reported by name"
elif [ "$N2_TOTAL" -ne 15 ]; then
    fail "N2: want 15 required readers across the three rules, enumerated $N2_TOTAL — the mapping shrank without the table being updated"
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

