#!/bin/bash
# tests/unit-staged-evidence-unstaged-tracked.sh
# Tests: hooks/workflow-gate/staged-evidence.js
# Tags: unit, staged-evidence, unstaged-tracked, workflow-gate, hook
#
# Unit tests for hasUnstagedTrackedChanges(repoDir).
# Expected red until #269 lands the function in staged-evidence.js.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
STAGED_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate/staged-evidence.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'unitstaged-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Build a git repo with an initial commit; echo Windows-friendly path.
init_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/seed.txt"
    git -C "$repo" add seed.txt
    git -C "$repo" commit -q -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Invoke hasUnstagedTrackedChanges(repoDir) via node -e and emit JSON.
call_helper() {
    local repo="$1"
    local q_staged q_repo
    q_staged="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$STAGED_JS")"
    q_repo="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$repo")"
    run_with_timeout 30 node -e "
const m = require($q_staged);
if (typeof m.hasUnstagedTrackedChanges !== 'function') {
  console.log(JSON.stringify({__missing: true}));
  process.exit(0);
}
const r = m.hasUnstagedTrackedChanges($q_repo);
console.log(JSON.stringify(r));
" 2>/dev/null
}

# Asserts the helper returned the clean shape: {hasChanges:false, files:[], error:null}.
assert_clean() {
    local label="$1" json="$2"
    if echo "$json" | grep -q '"__missing":true'; then
        fail "$label" "hasUnstagedTrackedChanges export missing"
        return
    fi
    if ! echo "$json" | grep -q '"hasChanges":false'; then
        fail "$label" "expected hasChanges:false, got: $json"
        return
    fi
    if ! echo "$json" | grep -q '"files":\[\]'; then
        fail "$label" "expected files:[], got: $json"
        return
    fi
    if ! echo "$json" | grep -q '"error":null'; then
        fail "$label" "expected error:null, got: $json"
        return
    fi
    pass "$label"
}

# ============================================================================
# Tests
# ============================================================================

# 1. clean repo (after initial commit, no modifications)
test_clean_repo() {
    local repo; repo="$(init_repo "clean")"
    local out; out="$(call_helper "$repo")"
    assert_clean "1: clean repo → hasChanges:false, files:[], error:null" "$out"
}

# 2. staged-only (one file edited and git add, nothing unstaged)
test_staged_only() {
    local repo; repo="$(init_repo "staged-only")"
    echo "edit" >> "$repo/seed.txt"
    git -C "$repo" add seed.txt
    local out; out="$(call_helper "$repo")"
    assert_clean "2: staged-only → hasChanges:false, files:[], error:null" "$out"
}

# 3. unstaged tracked single file
test_unstaged_single() {
    local repo; repo="$(init_repo "unstaged-single")"
    echo "src" > "$repo/app.js"
    git -C "$repo" add app.js
    git -C "$repo" commit -q -m "add app.js"
    echo "edit" >> "$repo/app.js"
    local out; out="$(call_helper "$repo")"
    if echo "$out" | grep -q '"__missing":true'; then
        fail "3: unstaged single → expected hasChanges:true" "helper export missing"
        return
    fi
    if ! echo "$out" | grep -q '"hasChanges":true'; then
        fail "3: unstaged single → expected hasChanges:true" "$out"
        return
    fi
    if ! echo "$out" | grep -q '"app.js"'; then
        fail "3: unstaged single → expected files to contain app.js" "$out"
        return
    fi
    if ! echo "$out" | grep -q '"error":null'; then
        fail "3: unstaged single → expected error:null" "$out"
        return
    fi
    pass "3: unstaged tracked single file → hasChanges:true, files:[app.js]"
}

# 4. mix (A staged + B unstaged) → files contains B, not A
test_mix_staged_and_unstaged() {
    local repo; repo="$(init_repo "mix")"
    echo "a" > "$repo/a.js"
    echo "b" > "$repo/b.js"
    git -C "$repo" add a.js b.js
    git -C "$repo" commit -q -m "seed a/b"
    echo "edit-a" >> "$repo/a.js"
    git -C "$repo" add a.js
    echo "edit-b" >> "$repo/b.js"
    local out; out="$(call_helper "$repo")"
    if echo "$out" | grep -q '"__missing":true'; then
        fail "4: mix → expected hasChanges:true" "helper export missing"
        return
    fi
    if ! echo "$out" | grep -q '"hasChanges":true'; then
        fail "4: mix → expected hasChanges:true" "$out"
        return
    fi
    if ! echo "$out" | grep -q '"b.js"'; then
        fail "4: mix → expected files to contain b.js" "$out"
        return
    fi
    if echo "$out" | grep -q '"a.js"'; then
        fail "4: mix → expected files NOT to contain a.js (it is staged)" "$out"
        return
    fi
    pass "4: mix staged+unstaged → files has b.js, not a.js"
}

# 5. untracked file only (.env created, no tracked changes)
test_untracked_only() {
    local repo; repo="$(init_repo "untracked")"
    echo "SECRET=x" > "$repo/.env"
    local out; out="$(call_helper "$repo")"
    assert_clean "5: untracked-only → hasChanges:false, files:[], error:null" "$out"
}

# 6. non-git directory → hasChanges:false, files:[], error:non-null string
test_non_git_dir() {
    local d="$TMPDIR_BASE/not-a-repo"
    mkdir -p "$d"
    local repo_node
    if command -v cygpath >/dev/null 2>&1; then
        repo_node="$(cygpath -m "$d")"
    else
        repo_node="$d"
    fi
    local out; out="$(call_helper "$repo_node")"
    if echo "$out" | grep -q '"__missing":true'; then
        fail "6: non-git dir → expected error string" "helper export missing"
        return
    fi
    if ! echo "$out" | grep -q '"hasChanges":false'; then
        fail "6: non-git dir → expected hasChanges:false" "$out"
        return
    fi
    if ! echo "$out" | grep -q '"files":\[\]'; then
        fail "6: non-git dir → expected files:[]" "$out"
        return
    fi
    if echo "$out" | grep -q '"error":null'; then
        fail "6: non-git dir → expected error to be a non-null string" "$out"
        return
    fi
    if ! echo "$out" | grep -qE '"error":"[^"]'; then
        fail "6: non-git dir → expected error to be a non-empty string" "$out"
        return
    fi
    pass "6: non-git dir → hasChanges:false, files:[], error:<string>"
}

run_all() {
    if [ ! -f "$AGENTS_DIR/hooks/workflow-gate/staged-evidence.js" ]; then
        fail "all: staged-evidence.js not present at expected path" "$STAGED_JS"
        return
    fi
    test_clean_repo
    test_staged_only
    test_unstaged_single
    test_mix_staged_and_unstaged
    test_untracked_only
    test_non_git_dir
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_UNIT_STAGED_INNER:-}" ]; then
        _UNIT_STAGED_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
