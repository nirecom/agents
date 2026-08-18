# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, git, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-extra-repos-dir-scan.sh (all cases).
# Cases: N1-N5, E1-E4, IDEM1, SEC1, INT1, INT2, ALIAS1.
# getSessionRepoRoots(): an ENFORCE_WORKTREE_ADDITIONAL_REPOS entry that is not a
# git repo root has its depth-1 subdirs scanned, so `C:\git` stands in for every
# repo under it. `[NEW]`/`[EXISTING]` suffixes are case identifiers — never trim.

# Needs a third state beyond the shared two-state guard_decision: 0=allow, 1=block,
# 2=malformed/empty (crash, no JSON, timeout) — a crash must not score as an allow.
rr_decision() {
    local out="$1"
    if [ -z "$out" ]; then return 2; fi
    if echo "$out" | grep -q '"decision":"block"'; then return 1; fi
    if echo "$out" | grep -qE '^\{\s*\}\s*$|"decision"\s*:'; then return 0; fi
    return 2
}

# Usage: rr_make_parent <parent> <repo-names...> — plain subdirs are separate.
rr_make_parent() {
    local parent="$1"; shift
    mkdir -p "$parent"
    local name
    for name in "$@"; do
        make_git_repo "$parent/$name"
    done
}

# Reach the target repo through `git -C <target>` so the DETECTED repo is the
# target rather than the CWD worktree; the trailing gh write is what the guard
# must then decide on.
rr_via() {
    local target="$1" cwd="$2" extras="$3"
    run_bash_guard "git -C \"$target\" rev-parse HEAD && gh pr merge 1" "$cwd" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$extras"
}

# $1=guard stdout $2=pass label $3=fail text $4=tag.
# The origin puts the tag AFTER the interpolated output — `<text> ($out) [NEW]` —
# and both halves are case identifiers, so the order is reproduced exactly.
rr_assert_allow() {
    if rr_decision "$1"; then pass "$2"; else fail "$3 ($1) $4"; fi
}

echo "=== EXTRA_REPOS directory scan (getSessionRepoRoots) ==="

# --- N1: parent dir with two git repos ---
rr_parent="$TMPDIR_BASE/N1-parent-$$"
rr_make_parent "$rr_parent" "repoA" "repoB"
rr_pair="$(setup_linked_worktree "N1-session")"; rr_wt="${rr_pair#*|}"
rr_parent_n="$(to_node_path "$rr_parent")"

rr_out="$(rr_via "$(to_node_path "$rr_parent/repoA")" "$rr_wt" "$rr_parent_n")"
rr_assert_allow "$rr_out" \
    "N1: parent dir scan — repoA reachable via git -C, gh write allows [NEW]" \
    "N1: parent dir scan — repoA should be in scope" "[NEW]"

rr_out="$(rr_via "$(to_node_path "$rr_parent/repoB")" "$rr_wt" "$rr_parent_n")"
rr_assert_allow "$rr_out" \
    "N1: parent dir scan — repoB reachable via git -C, gh write allows [NEW]" \
    "N1: parent dir scan — repoB should be in scope" "[NEW]"

# --- N2: individual repo path + parent dir in the same EXTRA_REPOS ---
rr_indiv="$TMPDIR_BASE/N2-individual"
make_git_repo "$rr_indiv"
rr_parent="$TMPDIR_BASE/N2-parent-$$"
rr_make_parent "$rr_parent" "child"
rr_pair="$(setup_linked_worktree "N2-session")"; rr_wt="${rr_pair#*|}"
rr_indiv_n="$(to_node_path "$rr_indiv")"
rr_extras="$rr_indiv_n;$(to_node_path "$rr_parent")"

rr_out="$(rr_via "$rr_indiv_n" "$rr_wt" "$rr_extras")"
rr_assert_allow "$rr_out" \
    "N2: mixed — individual repo (direct entry) in scope, allows [NEW]" \
    "N2: mixed — individual repo should be in scope" "[NEW]"

rr_out="$(rr_via "$(to_node_path "$rr_parent/child")" "$rr_wt" "$rr_extras")"
rr_assert_allow "$rr_out" \
    "N2: mixed — child-via-parent scan in scope, allows [NEW]" \
    "N2: mixed — child-via-parent scan should be in scope" "[NEW]"

# --- N3: whitespace around the separator must be trimmed ---
rr_a="$TMPDIR_BASE/N3-repoA"
make_git_repo "$rr_a"
rr_parent="$TMPDIR_BASE/N3-parent-$$"
rr_make_parent "$rr_parent" "child"
rr_pair="$(setup_linked_worktree "N3-session")"; rr_wt="${rr_pair#*|}"
rr_a_n="$(to_node_path "$rr_a")"
# The spaces around the entries are intentional — that is the case.
rr_extras=" $rr_a_n ; $(to_node_path "$rr_parent") "

rr_out="$(rr_via "$(to_node_path "$rr_parent/child")" "$rr_wt" "$rr_extras")"
rr_assert_allow "$rr_out" \
    "N3: space-after-comma trimmed — child-via-parent in scope [NEW]" \
    "N3: space-after-comma — child-via-parent should be in scope" "[NEW]"

rr_out="$(rr_via "$rr_a_n" "$rr_wt" "$rr_extras")"
rr_assert_allow "$rr_out" \
    "N3: space-after-comma trimmed — repoA (direct) still in scope [NEW]" \
    "N3: space-after-comma — repoA should be in scope" "[NEW]"

# --- N4: parent with no git repos below it is a no-op ---
rr_parent="$TMPDIR_BASE/N4-empty-parent-$$"
mkdir -p "$rr_parent/subdir1" "$rr_parent/subdir2"
rr_pair="$(setup_linked_worktree "N4-session")"; rr_wt="${rr_pair#*|}"
# A block here would mean the CWD repo was not detected — a base-code bug.
rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$(to_node_path "$rr_parent")")"
rr_assert_allow "$rr_out" \
    "N4: parent with no git repos — no-op, session wt still allowed [NEW]" \
    "N4: parent with no git repos — session wt should still be allowed" "[NEW]"

# --- N5: git repos and plain dirs side by side; only the repos are added ---
rr_parent="$TMPDIR_BASE/N5-parent-$$"
rr_make_parent "$rr_parent" "git-repo"
mkdir -p "$rr_parent/plain-dir" "$rr_parent/another-plain"
rr_pair="$(setup_linked_worktree "N5-session")"; rr_wt="${rr_pair#*|}"
rr_parent_n="$(to_node_path "$rr_parent")"

rr_out="$(rr_via "$(to_node_path "$rr_parent/git-repo")" "$rr_wt" "$rr_parent_n")"
rr_assert_allow "$rr_out" \
    "N5: mixed parent — git repo subdir in scope [NEW]" \
    "N5: mixed parent — git repo subdir should be in scope" "[NEW]"

rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$rr_parent_n" 2>&1)"
if echo "$rr_out" | grep -qiE 'unhandled|throw|Error:|TypeError'; then
    fail "N5: mixed parent — guard threw an error ($rr_out) [NEW]"
else
    pass "N5: mixed parent — guard did not crash on plain subdirs [NEW]"
fi

# --- E1: a nonexistent entry is skipped, the valid one still resolves ---
rr_pair="$(setup_linked_worktree "E1-session")"
rr_main="${rr_pair%|*}"; rr_wt="${rr_pair#*|}"
rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" ENFORCE_WORKTREE=on \
    "ENFORCE_WORKTREE_ADDITIONAL_REPOS=/totally/nonexistent/path/$$;$(to_node_path "$rr_main")")"
rr_assert_allow "$rr_out" \
    "E1: nonexistent path silently skipped, valid entry still works [EXISTING]" \
    "E1: nonexistent path should be skipped; valid entry should allow" "[EXISTING]"

# --- E2: empty and absent EXTRA_REPOS both leave only the CWD repo in scope ---
rr_pair="$(setup_linked_worktree "E2-session")"; rr_wt="${rr_pair#*|}"
rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_ADDITIONAL_REPOS=")"
rr_assert_allow "$rr_out" \
    "E2: EXTRA_REPOS='', cwd session wt allows [EXISTING]" \
    "E2: EXTRA_REPOS='', cwd session wt should allow" "[EXISTING]"

rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" ENFORCE_WORKTREE=on)"
rr_assert_allow "$rr_out" \
    "E2: EXTRA_REPOS unset, cwd session wt allows [EXISTING]" \
    "E2: EXTRA_REPOS unset, cwd session wt should allow" "[EXISTING]"

# --- E3: a file (not a directory) entry must not derail resolution ---
rr_pair="$(setup_linked_worktree "E3-session")"
rr_main="${rr_pair%|*}"; rr_wt="${rr_pair#*|}"
rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" ENFORCE_WORKTREE=on \
    "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$(to_node_path "$rr_main/README.md");$(to_node_path "$rr_main")")"
rr_assert_allow "$rr_out" \
    "E3: file path in EXTRA_REPOS skipped, valid entry still works [EXISTING]" \
    "E3: file path should be skipped/handled; valid entry should allow" "[EXISTING]"

# --- E4: an empty directory yields no repos and no error ---
rr_empty="$TMPDIR_BASE/E4-empty-$$"
mkdir -p "$rr_empty"
rr_pair="$(setup_linked_worktree "E4-session")"; rr_wt="${rr_pair#*|}"
rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$(to_node_path "$rr_empty")")"
rr_assert_allow "$rr_out" \
    "E4: empty dir in EXTRA_REPOS — no error, session wt still allows [EXISTING]" \
    "E4: empty dir should be handled gracefully; session wt should allow" "[EXISTING]"

# --- IDEM1: the same parent listed twice must dedup (Set), not double-add ---
rr_parent="$TMPDIR_BASE/IDEM1-parent-$$"
rr_make_parent "$rr_parent" "repo1"
rr_pair="$(setup_linked_worktree "IDEM1-session")"; rr_wt="${rr_pair#*|}"
rr_parent_n="$(to_node_path "$rr_parent")"
rr_repo1_n="$(to_node_path "$rr_parent/repo1")"
rr_extras="$rr_parent_n;$rr_parent_n"

rr_out="$(rr_via "$rr_repo1_n" "$rr_wt" "$rr_extras")"
rr_out2="$(rr_via "$rr_repo1_n" "$rr_wt" "$rr_extras")"
if [ "$rr_out" = "$rr_out2" ]; then
    pass "IDEM1: duplicate parent — identical output (Set dedup, idempotent) [NEW]"
else
    fail "IDEM1: duplicate parent — outputs differ (out1=$rr_out out2=$rr_out2) [NEW]"
fi
rr_assert_allow "$rr_out" \
    "IDEM1: duplicate parent — repo1 in scope, allows [NEW]" \
    "IDEM1: duplicate parent — repo1 should be in scope" "[NEW]"

# --- SEC1: EXTRA_REPOS is read as data, never handed to a shell ---
rr_pair="$(setup_linked_worktree "SEC1-session")"; rr_wt="${rr_pair#*|}"
rr_sentinel="$TMPDIR_BASE/sec1-injected-$$"
rr_payloads=(
    "/tmp/a;mkdir $rr_sentinel"
    "/tmp/a\$(mkdir $rr_sentinel)"
    "/tmp/a|mkdir $rr_sentinel"
    "/tmp/a\`mkdir $rr_sentinel\`"
)
for rr_p in "${rr_payloads[@]}"; do
    rm -rf "$rr_sentinel" 2>/dev/null
    rr_out="$(run_bash_guard "gh pr merge 1" "$rr_wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$rr_p" 2>/dev/null)"
    if [ -d "$rr_sentinel" ] || [ -e "$rr_sentinel" ]; then
        fail "SEC1: metachar '$rr_p' was shell-executed [EXISTING]"
        rm -rf "$rr_sentinel" 2>/dev/null
    else
        pass "SEC1: metachar '$rr_p' not executed [EXISTING]"
    fi
    if [ -n "$rr_out" ] && ! echo "$rr_out" | grep -qE '^\{.*\}$'; then
        fail "SEC1: metachar '$rr_p' produced malformed output ($rr_out) [EXISTING]"
    fi
done

# --- INT1/INT2: dir-scan widens scope; without it, git -C stays out of scope ---
rr_parent="$TMPDIR_BASE/INT1-parent-$$"
rr_make_parent "$rr_parent" "target-repo"
rr_pair="$(setup_linked_worktree "INT1-session")"; rr_wt="${rr_pair#*|}"
rr_out="$(rr_via "$(to_node_path "$rr_parent/target-repo")" "$rr_wt" "$(to_node_path "$rr_parent")")"
rr_assert_allow "$rr_out" \
    "INT1: EXTRA_REPOS=parent, gh pr merge targeting subdir repo allows [NEW]" \
    "INT1: EXTRA_REPOS=parent, subdir repo should be in scope" "[NEW]"

rr_pair="$(setup_linked_worktree "INT2-session")"; rr_wt="${rr_pair#*|}"
rr_pair2="$(setup_linked_worktree "INT2-target")"; rr_target="${rr_pair2#*|}"
rr_out="$(run_bash_guard \
    "git -C \"$(to_node_path "$rr_target")\" rev-parse HEAD && gh pr merge 1" \
    "$rr_wt" ENFORCE_WORKTREE=on)"
if rr_decision "$rr_out"; then
    fail "INT2: no EXTRA_REPOS, out-of-scope target should be blocked ($rr_out) [EXISTING]"
else
    pass "INT2: no EXTRA_REPOS, out-of-scope target via git -C blocked [EXISTING]"
fi

# --- ALIAS1: the deprecated ENFORCE_WORKTREE_EXTRA_REPOS spelling ---
# Kept verbatim on purpose: the alias must still be honoured when the ADDITIONAL
# name is unset, AND must warn on stderr. The warning half is a known red case.
# stderr has to be captured here, so this one bypasses run_bash_guard.
rr_pair="$(setup_linked_worktree "ALIAS1-session")"
rr_main="${rr_pair%|*}"; rr_wt="${rr_pair#*|}"
rr_stderr="$TMPDIR_BASE/alias1-stderr-$$"
rr_payload="$(node -e "
  const j = { session_id:'test-alias1', tool_name:'Bash', tool_input:{ command: 'gh pr merge 1' } };
  console.log(JSON.stringify(j));
" 2>/dev/null)"
rr_out="$(cd "$rr_wt" && echo "$rr_payload" | run_with_timeout 30 env \
    ENFORCE_WORKTREE=on \
    "ENFORCE_WORKTREE_EXTRA_REPOS=$(to_node_path "$rr_main")" \
    node "$GUARD_JS" 2>"$rr_stderr")" || true

rr_assert_allow "$rr_out" \
    "ALIAS1: EXTRA_REPOS deprecated alias — gh write still allows [NEW]" \
    "ALIAS1: EXTRA_REPOS deprecated alias — gh write should allow" "[NEW]"

if grep -q "is deprecated" "$rr_stderr" 2>/dev/null; then
    pass "ALIAS1: EXTRA_REPOS deprecated alias — 'is deprecated' warning on stderr [NEW]"
else
    fail "ALIAS1: EXTRA_REPOS deprecated alias — missing 'is deprecated' warning on stderr (expected red) [NEW]"
fi
rm -f "$rr_stderr"

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "repo-resolution.sh"
