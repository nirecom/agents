# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 5: P1-P5 — Concern 3 (HIGH) + Concern 7 (MEDIUM): table-driven
# path-prefix matching, per skills/_shared/test-design.md "Table-Driven
# Tests" and tests/feature-833-review-tests-sentinel-ssot.sh precedent. Each
# row stages exactly ONE brand-new file at <path> (no deletion at all — this
# is a pure path-filter check, orthogonal to the #1068 deletion bug) and
# asserts whether computeStagedTestsToken treats it as an in-scope tests/
# path (valid hex token) or an out-of-scope path (null, since the filtered
# path list is empty).
# EXPECTED: PASS both before and after the fix (the `tests/`/`test/` prefix
# filter is pre-existing code, not touched by the planned diff-filter fix).
# ===========================================================================

echo ""
echo "=== Table-driven: tests/ | test/ prefix matching (P1-P5) ==="

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# stage_single_path_repo <path> — builds an isolated repo under
# $TMPDIR_BASE/path-case-<n>, stages exactly one new file at <path>, and
# prints the repo directory to stdout for the caller to pass to
# call_compute_token.
_path_case_n=0
stage_single_path_repo() {
    local relpath="$1"
    _path_case_n=$((_path_case_n + 1))
    local repo="$TMPDIR_BASE/path-case-$_path_case_n"
    init_repo "$repo"
    mkdir -p "$repo/$(dirname "$relpath")"
    printf 'content\n' > "$repo/$relpath"
    git -C "$repo" add "$relpath"
    echo "$repo"
}

# result_kind <repoDir> — HEX if computeStagedTestsToken yields a valid hex
# token, NULL if it returns the literal null sentinel, OTHER otherwise.
result_kind() {
    local token
    token=$(call_compute_token "$1")
    if is_valid_hex_token "$token"; then
        echo "HEX"
    elif [ "$token" = "NULL" ]; then
        echo "NULL"
    else
        echo "OTHER:$token"
    fi
}

while IFS='|' read -r name relpath want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    relpath="${relpath#"${relpath%%[! ]*}"}"
    relpath="${relpath%"${relpath##*[! ]}"}"
    want="${want//[[:space:]]/}"
    repo=$(stage_single_path_repo "$relpath")
    got=$(result_kind "$repo")
    assert_eq "$name" "$want" "$got"
done <<'PATH_TABLE'
P1.tests-slash-prefix     | tests/example.sh          | HEX
P2.test-singular-prefix   | test/example.sh           | HEX
P3.tests-nested-subdir    | tests/sub/example.sh      | HEX
P4.src-no-match           | src/example.js            | NULL
P5.tests-prefix-lookalike | tests-prefix/example.sh   | NULL
PATH_TABLE
