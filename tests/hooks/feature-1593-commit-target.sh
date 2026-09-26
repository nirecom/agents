#!/usr/bin/env bash
# Tests: hooks/lib/commit-target.js, hooks/lib/bash-write-targets/staged.js
# Tags: hook, scan, commit, staged, git, security, scope:issue-specific
# Unit tests for #1593 staged-scan plumbing: extractStagedFilesRelative(repoRoot)
# (repo-relative forward-slash, ACM-filtered, [] on empty, null on failure) and
# resolveCommitRepoDir(command, baseDir) (sequential -C chain, absolute reset,
# empty no-op). Both symbols are new/unexported → pre-fix every case reports
# NOT_EXPORTED (a clean assertion failure, fail-before-fix for this branch).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
harness_isolate

STAGED_JS="$(np "$AGENTS_DIR/hooks/lib/bash-write-targets/staged.js")"
COMMIT_JS="$(np "$AGENTS_DIR/hooks/lib/commit-target.js")"

# Normalize a path for comparison: backslash → slash, drop trailing slash, lowercase.
norm_path() {
    local p="$1"
    p="${p//\\//}"
    p="${p%/}"
    printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]'
}

case_begin "staged-files-relative" "hooks/lib/bash-write-targets/staged.js"
# ─────────────────────────────────────────────────────────────────────────────
# Part 1 — extractStagedFilesRelative(repoRoot)
# ─────────────────────────────────────────────────────────────────────────────
# Echoes JSON array on success, NULL on null return, NOT_EXPORTED when missing.
call_staged() {
    local repo_node="$1"
    run_with_timeout 30 node -e '
      let m;
      try { m = require(process.argv[1]); } catch (e) { console.log("NOT_EXPORTED"); process.exit(2); }
      if (typeof m.extractStagedFilesRelative !== "function") { console.log("NOT_EXPORTED"); process.exit(2); }
      const r = m.extractStagedFilesRelative(process.argv[2]);
      if (r === null) { console.log("NULL"); process.exit(0); }
      console.log(JSON.stringify(r));
    ' -- "$STAGED_JS" "$repo_node" 2>/dev/null
}

new_repo() {
    local d="$1"
    harness_git_init "$d"
    git -C "$d" config user.email "t@example.com"
    git -C "$d" config user.name "T"
}

BROOT="$(make_tmp)"
trap 'rm -rf "$BROOT"' EXIT INT TERM HUP

# B1: one staged file → repo-relative forward-slash path (not absolute).
B1_REPO="$BROOT/b1"
new_repo "$B1_REPO"
printf 'x\n' > "$B1_REPO/foo.txt"
git -C "$B1_REPO" add foo.txt >/dev/null 2>&1
B1_OUT="$(call_staged "$(np "$B1_REPO")")"
case "$B1_OUT" in
    NOT_EXPORTED) fail "B1: extractStagedFilesRelative not exported (fail-before-fix)" ;;
    '["foo.txt"]') pass "B1: staged file → repo-relative forward-slash path" ;;
    *) fail "B1: expected [\"foo.txt\"], got: $B1_OUT" ;;
esac

# B2: nothing staged → [] (empty array, not null).
B2_REPO="$BROOT/b2"
new_repo "$B2_REPO"
B2_OUT="$(call_staged "$(np "$B2_REPO")")"
case "$B2_OUT" in
    NOT_EXPORTED) fail "B2: extractStagedFilesRelative not exported (fail-before-fix)" ;;
    '[]') pass "B2: nothing staged → [] (not null)" ;;
    *) fail "B2: expected [], got: $B2_OUT" ;;
esac

# B3: git spawn error / nonzero (non-git directory) → null.
B3_DIR="$BROOT/b3-not-a-repo"
mkdir -p "$B3_DIR"
B3_OUT="$(call_staged "$(np "$B3_DIR")")"
case "$B3_OUT" in
    NOT_EXPORTED) fail "B3: extractStagedFilesRelative not exported (fail-before-fix)" ;;
    NULL) pass "B3: git nonzero in non-git dir → null (fail-closed signal)" ;;
    *) fail "B3: expected NULL, got: $B3_OUT" ;;
esac

# B4: deleted file excluded by --diff-filter=ACM; a staged add is still reported.
B4_REPO="$BROOT/b4"
new_repo "$B4_REPO"
printf 'old\n' > "$B4_REPO/gone.txt"
git -C "$B4_REPO" add gone.txt >/dev/null 2>&1
git -C "$B4_REPO" -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
git -C "$B4_REPO" rm -q gone.txt >/dev/null 2>&1
printf 'new\n' > "$B4_REPO/added.txt"
git -C "$B4_REPO" add added.txt >/dev/null 2>&1
B4_OUT="$(call_staged "$(np "$B4_REPO")")"
case "$B4_OUT" in
    NOT_EXPORTED) fail "B4: extractStagedFilesRelative not exported (fail-before-fix)" ;;
    *)
        if grep -qF 'added.txt' <<<"$B4_OUT" && ! grep -qF 'gone.txt' <<<"$B4_OUT"; then
            pass "B4: --diff-filter=ACM keeps added.txt, drops deleted gone.txt"
        else
            fail "B4: expected added.txt present and gone.txt absent, got: $B4_OUT"
        fi
        ;;
esac

case_end
case_begin "commit-repo-dir" "hooks/lib/commit-target.js"
# ─────────────────────────────────────────────────────────────────────────────
# Part 2 — resolveCommitRepoDir(command, baseDir)
# ─────────────────────────────────────────────────────────────────────────────
# Base passed BOTH as arg2 and as child cwd, so the case holds whether the impl
# reads its base from the argument or from process.cwd().
call_resolve() {
    local cmd="$1" base_node="$2" base_bash="$3"
    (
        cd "$base_bash" && run_with_timeout 30 node -e '
          let m;
          try { m = require(process.argv[1]); } catch (e) { console.log("NOT_EXPORTED"); process.exit(2); }
          if (typeof m.resolveCommitRepoDir !== "function") { console.log("NOT_EXPORTED"); process.exit(2); }
          const r = m.resolveCommitRepoDir(process.argv[2], process.argv[3]);
          console.log(r === null || r === undefined ? "" : r);
        ' -- "$COMMIT_JS" "$cmd" "$base_node" 2>/dev/null
    )
}

assert_resolve() {
    local id="$1" cmd="$2" base_node="$3" base_bash="$4" expected_node="$5"
    local r got exp
    r="$(call_resolve "$cmd" "$base_node" "$base_bash")"
    case "$r" in
        NOT_EXPORTED) fail "$id: resolveCommitRepoDir not exported (fail-before-fix)"; return ;;
    esac
    got="$(norm_path "$r")"
    exp="$(norm_path "$expected_node")"
    if [ "$got" = "$exp" ]; then
        pass "$id: $cmd → $r"
    else
        fail "$id: expected $exp, got $got (raw=$r)"
    fi
}

# path.resolve needs no existence, but create dirs so an existence-checking impl resolves too.
BASE_BASH="$BROOT/base"; mkdir -p "$BASE_BASH/a/b"
ABS_BASH="$BROOT/absrepo"; mkdir -p "$ABS_BASH"
SPACE_BASH="$BROOT/with spaces"; mkdir -p "$SPACE_BASH"
BASE_NODE="$(np "$BASE_BASH")"
ABS_NODE="$(np "$ABS_BASH")"
SPACE_NODE="$(np "$SPACE_BASH")"
if command -v cygpath >/dev/null 2>&1; then
    ABS_LITERAL="$(cygpath -w "$ABS_BASH")"
    SPACE_LITERAL="$(cygpath -w "$SPACE_BASH")"
else
    ABS_LITERAL="$ABS_BASH"
    SPACE_LITERAL="$SPACE_BASH"
fi

# B5: bare `git commit` (no -C) → base (process cwd / toolInput.cwd).
assert_resolve "B5" "git commit -m x" "$BASE_NODE" "$BASE_BASH" "$BASE_NODE"

# B6: `git -C <abs> commit` → the absolute -C path.
assert_resolve "B6" "git -C \"$ABS_LITERAL\" commit" "$BASE_NODE" "$BASE_BASH" "$ABS_NODE"

# B7: `git --no-pager -C "<abs path with spaces>" commit` → unquoted path with spaces.
assert_resolve "B7" "git --no-pager -C \"$SPACE_LITERAL\" commit" "$BASE_NODE" "$BASE_BASH" "$SPACE_NODE"

# B8: `git -C a -C b commit` → sequential base/a/b (NOT last-wins base/b).
assert_resolve "B8" "git -C a -C b commit" "$BASE_NODE" "$BASE_BASH" "$BASE_NODE/a/b"

# B9: absolute -C resets the chain → `git -C a -C <abs> commit` = <abs>.
assert_resolve "B9" "git -C a -C \"$ABS_LITERAL\" commit" "$BASE_NODE" "$BASE_BASH" "$ABS_NODE"

# B10: empty -C is a no-op → `git -C a -C "" -C b commit` = base/a/b.
assert_resolve "B10" "git -C a -C \"\" -C b commit" "$BASE_NODE" "$BASE_BASH" "$BASE_NODE/a/b"

case_end

echo ""
echo "─────────────────────────────────────────"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
