# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, fingerprint, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 5: P1-P6 — table-driven path-scope matching for computeReviewScopeFingerprint.
# Each row stages exactly ONE brand-new file at <path> and asserts whether the
# function treats it as in-scope (HEX fingerprint) or excluded (EMPTY — excluded
# by isReviewScopeExcludedPath: docs/, CHANGELOG.md, changelog/*.md, root README.md).
# Implementation files like src/ are now in-scope (unlike the old tests-only filter).
# ===========================================================================

echo ""
echo "=== Table-driven: review-scope path inclusion/exclusion (P1-P6) ==="

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

# result_kind <repoDir> — HEX if computeReviewScopeFingerprint yields a valid hex
# fingerprint, EMPTY if ok:true but no in-scope files, ERR if ok:false, OTHER otherwise.
result_kind() {
    local fp
    fp=$(call_compute_fingerprint "$1")
    if is_valid_hex_token "$fp"; then
        echo "HEX"
    elif [ "$fp" = "EMPTY" ]; then
        echo "EMPTY"
    elif [ "$fp" = "ERR" ]; then
        echo "ERR"
    else
        echo "OTHER:$fp"
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
P4.src-impl-in-scope      | src/example.js            | HEX
P5.tests-prefix-in-scope  | tests-prefix/example.sh   | HEX
P6.changelog-excluded     | CHANGELOG.md              | EMPTY
PATH_TABLE
