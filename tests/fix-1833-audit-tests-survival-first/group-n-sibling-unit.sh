# Group N: a test file plus its populated tests/<stem>/ sibling is ONE unit (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, sibling-unit, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# The split-file convention this very test suite uses — a dispatcher
# `tests/<stem>.sh` next to a `tests/<stem>/` folder of group files — makes the
# retire unit a PAIR, not a file. Two failure modes are specific to it:
#   - partial deletion: the dispatcher is removed and the folder is orphaned
#     (or the reverse), leaving a tests/ tree that no longer runs; and
#   - metadata drift: `last_commit` / `sibling_file_count` are computed from the
#     dispatcher alone, so a stem whose real work all happened inside the folder
#     looks far more abandoned than it is.
# Both are invisible to every single-file fixture in groups A/B/G.

N_REPO="$(make_repo)"
add_src "$N_REPO" "bin/alive-n.sh"

# n_unit <root> <stem> <header> <n-group-files> [tags] — dispatcher + sibling dir
n_unit() {
    local root="$1" stem="$2" hdr="$3" count="$4" tags="${5:-TL2, scope:common}" i
    add_test_file "$root" "${stem}.sh" "$hdr" "$tags"
    mkdir -p "$root/tests/$stem"
    for ((i = 1; i <= count; i++)); do
        {
            printf '# Tests: %s\n' "$hdr"
            printf '# Tags: %s\n' "$tags"
            printf 'echo group-%s\n' "$i"
        } > "$root/tests/$stem/group-$i.sh"
    done
}

# Issue-specific unit, 3 group files, every target dead, issue closed and stale
# => the whole unit is authorised for deletion.
n_unit "$N_REPO" "feature-1301-deadunit" "bin/gone-n1.sh" 3 "TL2, scope:issue-specific"
# Common-scope unit, 2 group files, dead target, no issue reference => likewise.
n_unit "$N_REPO" "cc-deadunit-n" "bin/gone-n2.sh" 2
# Control: a unit whose target is ALIVE. Nothing about it may be reported or
# removed — a sibling folder must not become a deletion trigger of its own.
n_unit "$N_REPO" "cc-liveunit-n" "bin/alive-n.sh" 2
commit_repo "$N_REPO" "sibling-unit fixture"

N_STUB="$TMPDIR_BASE/n-stub"
install_gh_mock "$N_STUB"
export MOCK_ISSUES="1301 closed 2019-01-01T00:00:00Z"

N_ALL="$(cd "$N_REPO" && git ls-files 'tests/*' | sort)"
assert_eq "N0 fixture starts with 10 tracked test paths" "10" "$(printf '%s\n' "$N_ALL" | grep -c .)"

# ── N1: the report names the sibling folder and counts its files ────────────

run_in_repo "$N_REPO" "$N_STUB" "$AUDIT" --dry-run --format text
N1_OUT="$OUT"

assert_eq "N1a the unit is reported as one candidate, keyed on the dispatcher" \
    "candidate" "$(report_of "$N1_OUT" "tests/feature-1301-deadunit.sh")"

# N1b — the sibling folder is named with its exact file count. A count computed
# from the dispatcher alone (or a recursive count that also swept the
# dispatcher) both fail here.
if printf '%s\n' "$N1_OUT" | grep -qE "Sibling folder: tests/feature-1301-deadunit/ \(3 files\)"; then
    pass "N1b the report names the sibling folder with its 3-file count"
else
    fail "N1b expected 'Sibling folder: tests/feature-1301-deadunit/ (3 files)' (out=<<$N1_OUT>>)"
fi

# N1c — and it states the deletion unit explicitly, so the reader knows the
# folder goes with it before authorising anything.
if printf '%s\n' "$N1_OUT" | grep -qE "Deletion unit: tests/feature-1301-deadunit\.sh tests/feature-1301-deadunit/"; then
    pass "N1c the report states the two-part deletion unit"
else
    fail "N1c the report does not state the dispatcher+folder deletion unit (out=<<$N1_OUT>>)"
fi

# N1d — the group files inside the folder are NOT reported as candidates in
# their own right; they are not top-level tests and have no independent life.
N1D_GOT=""
for n_g in 1 2 3; do
    N1D_GOT="$N1D_GOT$(report_of "$N1_OUT" "tests/feature-1301-deadunit/group-$n_g.sh") "
done
assert_eq "N1d group files inside the sibling folder are not separately reported" \
    "none none none" "${N1D_GOT% }"

# ── N2: the same two facts in the JSON document ─────────────────────────────

run_in_repo "$N_REPO" "$N_STUB" "$AUDIT" --dry-run --format json
N2_JSON="$OUT"
if json_parses "$N2_JSON"; then
    pass "N2a --format json parses with a sibling-bearing candidate"
else
    fail "N2a sibling metadata corrupted the JSON document (out=<<$N2_JSON>>)"
fi
assert_eq "N2b the candidate's sibling key carries the folder path" \
    "tests/feature-1301-deadunit/" \
    "$(json_query "$N2_JSON" '((d.candidates||[]).find(c=>c.dispatcher==="tests/feature-1301-deadunit.sh")||{}).sibling')"
assert_eq "N2c sibling_file_count matches the 3 files really in the folder" \
    "3" \
    "$(json_query "$N2_JSON" '((d.candidates||[]).find(c=>c.dispatcher==="tests/feature-1301-deadunit.sh")||{}).sibling_file_count')"

# ── N3: --apply removes the WHOLE unit, atomically, on both scripts ─────────

run_in_repo "$N_REPO" "$N_STUB" "$AUDIT" --apply --format text
N3_OUT="$OUT"
run_in_repo "$N_REPO" "$N_STUB" "$AUDIT_COMMON" --apply --format text
N3C_OUT="$OUT"

assert_gate_row "N3a the issue-specific dispatcher is deleted" \
    "$N3_OUT" "$N_REPO" "tests/feature-1301-deadunit.sh" candidate deleted gone
assert_eq "N3b its sibling folder went with it — no orphaned directory remains" \
    "gone" "$(fs_of "$N_REPO" "tests/feature-1301-deadunit")"

# The common script deletes now too (#1833), so it owes the same atomicity —
# CPR-5: same class of unit, same treatment.
assert_gate_row "N3c the common dispatcher is deleted" \
    "$N3C_OUT" "$N_REPO" "tests/cc-deadunit-n.sh" orphan deleted gone
assert_eq "N3d the common sibling folder went with it" \
    "gone" "$(fs_of "$N_REPO" "tests/cc-deadunit-n")"

# N3e — every removed path is STAGED, and the count is the full unit
# (1 dispatcher + 3 groups) + (1 dispatcher + 2 groups) = 7 staged deletions.
# A partial deletion shows up here as a smaller number even when both fs_of
# checks above pass (e.g. folder rm'd from disk but never staged).
assert_eq "N3e the index holds exactly the seven staged unit deletions" \
"D  tests/cc-deadunit-n.sh
D  tests/cc-deadunit-n/group-1.sh
D  tests/cc-deadunit-n/group-2.sh
D  tests/feature-1301-deadunit.sh
D  tests/feature-1301-deadunit/group-1.sh
D  tests/feature-1301-deadunit/group-2.sh
D  tests/feature-1301-deadunit/group-3.sh" \
"$(git -C "$N_REPO" status --porcelain | sort)"

# N3f — the live unit is fully intact: neither its dispatcher nor its folder.
assert_eq "N3f the alive unit survives whole" \
    "kept kept" \
    "$(fs_of "$N_REPO" "tests/cc-liveunit-n.sh") $(fs_of "$N_REPO" "tests/cc-liveunit-n")"

unset MOCK_ISSUES
