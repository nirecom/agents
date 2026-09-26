# Group E: rename-aware survival (a moved target still counts as alive) (#2081)
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# Case survival is exists(target) but rename-aware via find_renamed_path: a case
# whose target was git-renamed is still surviving, so a unit of only-renamed
# cases stays `alive` (refcount == case count), never a false orphan.

if ! require_fn trp_case_refcount_verdict "E0"; then return 0; fi

E_REPO="$(make_repo)"
add_src "$E_REPO" "bin/e-old1.sh"
add_src "$E_REPO" "bin/e-old2.sh"
add_raw "$E_REPO" "e-rename.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/e-old1.sh, bin/e-old2.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/e-old1.sh"
case_end
case_begin "b" "bin/e-old2.sh"
case_end
EOF
commit_repo "$E_REPO" "group-e pre-rename baseline"

# Rename both targets with history-preserving git mv, then commit.
git -C "$E_REPO" mv "bin/e-old1.sh" "bin/e-new1.sh" >/dev/null 2>&1
git -C "$E_REPO" mv "bin/e-old2.sh" "bin/e-new2.sh" >/dev/null 2>&1
commit_repo "$E_REPO" "group-e rename targets"

run_verdict "$E_REPO" "tests/e-rename.sh"
assert_eq "E1 renamed targets count as surviving → alive" "alive" "${TRP_VERDICT:-x}"
assert_eq "E1b refcount equals case count (rename-aware)" "2" "${TRP_REFCOUNT:-x}"
assert_eq "E1c no orphan cases from renames" "0" "${#TRP_ORPHAN_CASE_IDX[@]}"

# E2 — one renamed, one truly deleted → partial-orphan (only the deleted case).
E2_REPO="$(make_repo)"
add_src "$E2_REPO" "bin/e2-keep.sh"
add_src "$E2_REPO" "bin/e2-gone.sh"
add_raw "$E2_REPO" "e2-mixed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/e2-keep.sh, bin/e2-gone.sh
# Tags: TL2, scope:issue-specific
case_begin "keep" "bin/e2-keep.sh"
case_end
case_begin "gone" "bin/e2-gone.sh"
case_end
EOF
commit_repo "$E2_REPO" "group-e2 baseline"
git -C "$E2_REPO" mv "bin/e2-keep.sh" "bin/e2-kept.sh" >/dev/null 2>&1
git -C "$E2_REPO" rm -q "bin/e2-gone.sh" >/dev/null 2>&1
commit_repo "$E2_REPO" "group-e2 rename one, delete one"

run_verdict "$E2_REPO" "tests/e2-mixed.sh"
assert_eq "E2 rename+delete → partial-orphan" "partial-orphan" "${TRP_VERDICT:-x}"
assert_eq "E2b only the deleted case is orphan" "1" "${TRP_REFCOUNT:-x}"
