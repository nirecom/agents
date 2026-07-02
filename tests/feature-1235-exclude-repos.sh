#!/bin/bash
# tests/feature-1235-exclude-repos.sh
# Tests: hooks/enforce-worktree/config.js, hooks/pre-commit, hooks/enforce-worktree.js
# Tags: enforce-worktree, hook, git, pre-commit, security, scope:issue-specific, pwsh-not-required
#
# Three-part test suite for ENFORCE_WORKTREE_EXCLUDE_REPOS path-based exclusion.
#
# Part A: isRepoExcluded(repoDir) unit (table-driven, node driver)
# Part B: hooks/pre-commit integration (temp git repo, direct hook invocation)
# Part C: hooks/enforce-worktree.js integration (JSON stdin → allow/block)
#
# Security pattern 2 (attack scenario): the EXCLUDE_REPOS gate, once implemented,
# must allow excluded repos and block non-excluded repos. Tests targeting the
# "allow excluded repo" path FAIL against unimplemented code (RED) because the
# function does not exist yet. Tests targeting the "block non-excluded" path may
# already PASS (existing enforcement is intact).
#
# L3 gap (what this test does NOT catch):
# - real Claude Code Bash tool session with live enforce-worktree hook registration
# - Windows path normalisation (drive letter casing) in a live session
# - hook loading from settings.json (settings path wiring not tested here)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_NODE="$AGENTS_DIR"
fi

CONFIG_JS="$AGENTS_DIR/hooks/enforce-worktree/config.js"
HOOK_JS="$AGENTS_DIR/hooks/enforce-worktree.js"
PRE_COMMIT="$AGENTS_DIR/hooks/pre-commit"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# PART A — isRepoExcluded unit (table-driven, node driver)
# ═══════════════════════════════════════════════════════════════════════════════

echo "=== Part A: isRepoExcluded unit (table-driven) ==="

DRIVER_A="$TMPBASE/driver-a.js"
cat > "$DRIVER_A" <<'NODE'
"use strict";
// argv[2]=agentsNode argv[3]=exclude_env argv[4]=dir
const path = require("path");
const AGENTS_NODE  = process.argv[2];
const EXCLUDE_ENV  = process.argv[3] || "";
const DIR          = process.argv[4] || "";

process.env.ENFORCE_WORKTREE_EXCLUDE_REPOS = EXCLUDE_ENV;

let mod;
try {
    mod = require(path.join(AGENTS_NODE, "hooks", "enforce-worktree", "config.js"));
} catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND") {
        process.stdout.write(JSON.stringify({ ok: false, missing: true, error: "config.js MODULE_NOT_FOUND" }) + "\n");
        process.exit(0);
    }
    process.stdout.write(JSON.stringify({ ok: false, error: String((e && e.message) || e) }) + "\n");
    process.exit(0);
}

if (typeof mod.isRepoExcluded !== "function") {
    process.stdout.write(JSON.stringify({ ok: false, missing: true, error: "isRepoExcluded not yet exported from config.js" }) + "\n");
    process.exit(0);
}

try {
    const v = mod.isRepoExcluded(DIR);
    process.stdout.write(JSON.stringify({ ok: true, value: !!v }) + "\n");
} catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: String((e && e.message) || e) }) + "\n");
}
NODE

# call_excluded exclude_env dir → JSON
call_excluded() {
    local exclude_env="$1" dir="$2"
    run_with_timeout 10 node "$DRIVER_A" "$_AGENTS_NODE" "$exclude_env" "$dir" 2>/dev/null
}

assert_excluded() {
    local name="$1" exclude_env="$2" dir="$3" want="$4"
    local out got
    out="$(call_excluded "$exclude_env" "$dir")"
    if echo "$out" | grep -q '"missing":true'; then
        fail "$name — isRepoExcluded not yet implemented"
        return
    fi
    if ! echo "$out" | grep -q '"ok":true'; then
        fail "$name — driver error: $out"
        return
    fi
    got="$(echo "$out" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(j.value?'true':'false');")"
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name — want=$want got=$got (exclude='$exclude_env' dir='$dir')"
    fi
}

# Build platform-correct absolute test paths via node
build_test_paths() {
    node -e "
const path=require('path');
const sep=process.platform==='win32'?'\\\\':'/';
const base=path.resolve(process.env.TMPBASE || '/tmp');
// Output JSON of {exact, sub, sibling, other, multi1, multi2}
const exact=path.join(base,'a','b','repo');
const sub=path.join(exact,'sub');
const sibling=path.join(base,'a','b','ai-specs-old');
const entry=path.join(base,'a','b','ai-specs');
const other=path.join(base,'x','y','repo');
const multi1=path.join(base,'p1','repo');
const multi2=path.join(base,'p2','repo');
const upper=path.join(base,'A','B','Repo');
const lower=path.join(base,'a','b','repo');
console.log(JSON.stringify({exact,sub,sibling,entry,other,multi1,multi2,upper,lower}));
" 2>/dev/null
}

PATHS_JSON="$(TMPBASE="$TMPBASE" build_test_paths)"
get_path() { echo "$PATHS_JSON" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); process.stdout.write(j['$1']);" 2>/dev/null; }

P_EXACT="$(get_path exact)"
P_SUB="$(get_path sub)"
P_SIBLING="$(get_path sibling)"
P_ENTRY="$(get_path entry)"
P_OTHER="$(get_path other)"
P_MULTI1="$(get_path multi1)"
P_MULTI2="$(get_path multi2)"
P_UPPER="$(get_path upper)"
P_LOWER="$(get_path lower)"

# Table-driven cases — IFS='|' loop per test-design.md
while IFS='|' read -r name exclude_key dir_key want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    want="${want#"${want%%[![:space:]]*}"}"
    want="${want%"${want##*[![:space:]]}"}"
    exclude_key="${exclude_key#"${exclude_key%%[![:space:]]*}"}"
    exclude_key="${exclude_key%"${exclude_key##*[![:space:]]}"}"
    dir_key="${dir_key#"${dir_key%%[![:space:]]*}"}"
    dir_key="${dir_key%"${dir_key##*[![:space:]]}"}"

    # Resolve paths from keys
    case "$exclude_key" in
        EXACT)   excl="$P_EXACT" ;;
        ENTRY)   excl="$P_ENTRY" ;;
        UPPER)   excl="$P_UPPER" ;;
        MULTI)   excl="${P_MULTI1};${P_MULTI2}" ;;
        EMPTY)   excl="" ;;
        *)       excl="$exclude_key" ;;
    esac
    case "$dir_key" in
        EXACT)   dir="$P_EXACT" ;;
        SUB)     dir="$P_SUB" ;;
        SIBLING) dir="$P_SIBLING" ;;
        ENTRY)   dir="$P_ENTRY" ;;
        OTHER)   dir="$P_OTHER" ;;
        MULTI1)  dir="$P_MULTI1" ;;
        MULTI2)  dir="$P_MULTI2" ;;
        LOWER)   dir="$P_LOWER" ;;
        *)       dir="$dir_key" ;;
    esac

    assert_excluded "$name" "$excl" "$dir" "$want"
done <<'TABLE'
exact-match                | EXACT   | EXACT   | true
subdir-under-entry         | EXACT   | SUB     | true
unset-empty-env            | EMPTY   | EXACT   | false
dir-not-in-list            | EXACT   | OTHER   | false
sibling-prefix-false-pos   | ENTRY   | SIBLING | false
multi-entry-second-matches | MULTI   | MULTI2  | true
case-insensitive-match     | UPPER   | LOWER   | true
TABLE

# ═══════════════════════════════════════════════════════════════════════════════
# PART B — hooks/pre-commit integration (real temp git repo)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Part B: hooks/pre-commit integration ==="

if [ ! -f "$PRE_COMMIT" ]; then
    skip "Part B — hooks/pre-commit not present"
else

RUN_OUT=""
run_pre_commit() {
    local cwd="$1"; shift
    local rc=0
    RUN_OUT="$(cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 env "$@" bash "$PRE_COMMIT" 2>&1)" || rc=$?
    return $rc
}

setup_repo() {
    local name="$1"
    local repo="$TMPBASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    # Bootstrap commit bypassing the hook
    echo "init" > "$repo/README.md"
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "initial" >/dev/null 2>&1
    echo "$repo"
}

stage_file() {
    local repo="$1" rel="$2" content="$3"
    mkdir -p "$(dirname "$repo/$rel")"
    printf '%s\n' "$content" > "$repo/$rel"
    git -C "$repo" -c core.hooksPath=/dev/null add "$rel" >/dev/null 2>&1
}

# Part B-1: EXCLUDE_REPOS matches repo → commit allowed (RED until implemented)
# Pattern 2 (attack scenario): without the exclusion the hook blocks; with
# EXCLUDE_REPOS set to the repo, the hook must allow.
REPO_B1="$(setup_repo "b1-exclude-match")"
stage_file "$REPO_B1" "src/x.txt" "clean content"

# Confirm baseline: without exclusion the hook blocks (sanity check — should PASS now)
if run_pre_commit "$REPO_B1" ENFORCE_WORKTREE=on; then
    fail "Part B baseline: main-worktree commit without EXCLUDE should block but didn't"
else
    pass "Part B baseline: main-worktree commit blocked without EXCLUDE (sanity)"
fi

# Now test with EXCLUDE_REPOS — should allow (RED until implemented)
if run_pre_commit "$REPO_B1" ENFORCE_WORKTREE=on \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=$REPO_B1"; then
    # Negative assertion (Pattern 1): confirm the output does NOT contain the
    # "commits from main worktree are blocked" message
    if echo "$RUN_OUT" | grep -qi "commits from main worktree are blocked\|protected branch"; then
        fail "Part B-1: EXCLUDE_REPOS matches repo but block message still present — not yet implemented"
    else
        pass "Part B-1: EXCLUDE_REPOS matches repo → pre-commit exits 0 (enforce gate bypassed)"
    fi
else
    fail "Part B-1: EXCLUDE_REPOS matches repo → expected exit 0 (not yet implemented)"
fi

# Part B-2: EXCLUDE_REPOS unset → existing enforcement fires (should PASS now)
REPO_B2="$(setup_repo "b2-no-exclude")"
stage_file "$REPO_B2" "src/y.txt" "content"
if run_pre_commit "$REPO_B2" ENFORCE_WORKTREE=on; then
    fail "Part B-2: EXCLUDE_REPOS unset → pre-commit should block but didn't"
else
    if echo "$RUN_OUT" | grep -qi "commits from main worktree are blocked\|protected branch"; then
        pass "Part B-2: EXCLUDE_REPOS unset → pre-commit blocks with expected message"
    else
        pass "Part B-2: EXCLUDE_REPOS unset → pre-commit blocked (message may vary)"
    fi
fi

# Part B-3: SIBLING-PREFIX false positive
# EXCLUDE_REPOS=<parent>/ai-specs, repo is <parent>/ai-specs-old → must BLOCK
PARENT_B3="$TMPBASE/b3-parent"
REPO_B3_ENTRY="$PARENT_B3/ai-specs"
REPO_B3="$PARENT_B3/ai-specs-old"
mkdir -p "$REPO_B3_ENTRY" "$REPO_B3"
# We don't need a real repo at ENTRY — just set EXCLUDE_REPOS to point there
# Then test that the actual repo (ai-specs-old) is NOT excluded
git -C "$REPO_B3" init -q -b main 2>/dev/null || git -C "$REPO_B3" init -q
git -C "$REPO_B3" config user.email "test@example.com"
git -C "$REPO_B3" config user.name "Test"
echo "init" > "$REPO_B3/README.md"
AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
    git -C "$REPO_B3" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1
AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
    git -C "$REPO_B3" -c core.hooksPath=/dev/null commit -q -m "initial" >/dev/null 2>&1
stage_file "$REPO_B3" "src/z.txt" "content"

if run_pre_commit "$REPO_B3" ENFORCE_WORKTREE=on \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=$REPO_B3_ENTRY"; then
    fail "Part B-3: SIBLING-PREFIX — ai-specs-old should not be excluded by ai-specs entry (boundary bug)"
else
    pass "Part B-3: SIBLING-PREFIX — ai-specs-old correctly blocked despite sibling ai-specs in EXCLUDE_REPOS"
fi

fi # pre-commit present

# ═══════════════════════════════════════════════════════════════════════════════
# PART C — hooks/enforce-worktree.js integration (JSON stdin)
# Strategy: use a Bash `git -C <mainWt> commit -m test` payload, which
# findRepoRootForBash() resolves to the actual main worktree path.
# This reliably blocks without session-scope concerns (Bash git write is always
# classified as "write" and the repo root resolves correctly when the path exists).
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Part C: hooks/enforce-worktree.js integration ==="

if [ ! -f "$HOOK_JS" ]; then
    skip "Part C — hooks/enforce-worktree.js not present"
else

# Discover the real main worktree (always the first entry of worktree list)
_MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree[[:space:]]+/, ""); print; exit}')"
if command -v cygpath >/dev/null 2>&1; then
    _MAIN_WT_NODE="$(cygpath -m "$_MAIN_WT" 2>/dev/null || echo "$_MAIN_WT")"
else
    _MAIN_WT_NODE="$_MAIN_WT"
fi

if [ -z "$_MAIN_WT" ] || [ ! -d "$_MAIN_WT" ]; then
    skip "Part C — cannot detect main worktree; skipping all Part C tests"
else

run_hook() {
    local json="$1"; shift
    local out
    out="$(echo "$json" | run_with_timeout 15 env AGENTS_CONFIG_DIR="$AGENTS_DIR" "$@" \
        node "$HOOK_JS" 2>/dev/null)" || true
    echo "$out"
}

is_allow() { echo "$1" | node -e "try{const j=JSON.parse(require('fs').readFileSync(0,'utf8'));process.exit(Object.keys(j).length===0?0:1);}catch(e){process.exit(1);}" 2>/dev/null; }
is_block() { echo "$1" | grep -q '"block"'; }

# Part C-1: Baseline — Bash git commit to real main worktree → hook blocks (sanity)
# Using git -C <mainWt> commit: findRepoRootForBash resolves mainWt, isMainCheckout → true → block
JSON_C1='{"tool_name":"Bash","tool_input":{"command":"git -C \"'"$_MAIN_WT_NODE"'\" commit -m test","cwd":"'"$_MAIN_WT_NODE"'"},"session_id":"test-c1-$$"}'
OUT_C1="$(run_hook "$JSON_C1" ENFORCE_WORKTREE=on)"
if is_block "$OUT_C1"; then
    pass "Part C baseline: git commit to main worktree → hook blocks"
else
    fail "Part C baseline: expected block for main-worktree git commit, got: $OUT_C1"
fi

# Part C-2: EXCLUDE_REPOS=<mainWt> → hook allows (RED until implemented)
# Pattern 2 (attack scenario): the same git commit command that blocks in C-1 should
# be allowed when mainWt is in EXCLUDE_REPOS. This FAILS until isRepoExcluded is
# integrated into the hook dispatch.
JSON_C2='{"tool_name":"Bash","tool_input":{"command":"git -C \"'"$_MAIN_WT_NODE"'\" commit -m test","cwd":"'"$_MAIN_WT_NODE"'"},"session_id":"test-c2-$$"}'
OUT_C2="$(run_hook "$JSON_C2" ENFORCE_WORKTREE=on \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=$_MAIN_WT_NODE")"
if is_allow "$OUT_C2"; then
    pass "Part C-2: EXCLUDE_REPOS=<mainWt> → hook allows ({})"
elif is_block "$OUT_C2"; then
    # Negative assertion (Pattern 1): the excluded repo must NOT produce a block message
    fail "Part C-2: EXCLUDE_REPOS=<mainWt> → expected allow, got block — isRepoExcluded not yet implemented in hook dispatch"
else
    fail "Part C-2: unexpected hook output: $OUT_C2 — not yet implemented"
fi

fi # _MAIN_WT available
fi # hook present

echo ""
echo "================================"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
