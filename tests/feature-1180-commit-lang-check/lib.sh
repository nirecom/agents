# tests/feature-1180-commit-lang-check/lib.sh
# Shared harness for the feature-1180-commit-lang-check dispatcher.
# Sourced by tests/feature-1180-commit-lang-check.sh — not executable standalone.
# Provides: AGENTS_DIR, LINT_LIB(_NODE), LANG_BLOCK_MARKER, PASS/FAIL counters,
# TMPDIR_BASE (+ EXIT trap), and the pass/fail/run_with_timeout/require_sut/
# make_git_repo/run_precommit/run_check_node/json_violations_empty helpers.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

LINT_LIB="$AGENTS_DIR/hooks/lib/lint-commit-lang.js"
if command -v cygpath >/dev/null 2>&1; then
    LINT_LIB_NODE="$(cygpath -m "$LINT_LIB")"
else
    LINT_LIB_NODE="$LINT_LIB"
fi

# Marker substring emitted by the planned pre-commit CODE_LANG block. Blocked
# assertions require this to distinguish a language block from the worktree gate
# and the private-info scanner (prevents false-green).
LANG_BLOCK_MARKER="CODE_LANG policy violation"

PASS=0
FAIL=0

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'clangcheck-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Guard: skip case with clean FAIL if the SUT module is absent.
require_sut() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then return 0; fi
    fail "$label: $(basename "$path") not found (RED until /write-code)"
    return 1
}

# Create a minimal temp git repo with user config, hooks disabled for setup
# commits (core.hooksPath /dev/null), and an initial commit so HEAD exists.
# Prints the repo path.
make_git_repo() {
    local name="$1"
    local dir="$TMPDIR_BASE/$name-$RANDOM-$$"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    echo "init" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
    echo "$dir"
}

# Run hooks/pre-commit directly from within the repo (proven pattern from
# feature-workflow-off-bypass-pre-commit.sh run_precommit). Extra env vars are
# passed as trailing name=val args via env. Prints stdout+stderr; sets PC_RC.
PC_RC=0
run_precommit() {
    local repo="$1"; shift
    PC_RC=0
    local out
    out="$( (cd "$repo" && run_with_timeout 30 env "$@" bash "$AGENTS_DIR/hooks/pre-commit") 2>&1 )" || PC_RC=$?
    printf '%s' "$PC_RC" > "$TMPDIR_BASE/.last_pc_rc"
    echo "$out"
}

# Run node one-liner requiring the real LINT_LIB with process.cwd() = the temp
# git repo. AGENTS_CONFIG_DIR points at the real repo (where the module lives);
# CODE_LANG is passed as a direct env var (wins over real .env). check() is
# called with NO args (matches the production call site in hooks/pre-commit).
# Args: $1=repo, $2=CODE_LANG value (may be empty). Prints check() JSON.
run_check_node() {
    local repo="$1" lang="$2"
    (cd "$repo" && run_with_timeout 15 env \
        CODE_LANG="$lang" \
        AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        node -e "
        const m = require('$LINT_LIB_NODE');
        process.stdout.write(JSON.stringify(m.check()));
    " 2>/dev/null)
}

# Assert result JSON has zero violations. Reads JSON on stdin, exits 0 if empty.
json_violations_empty() {
    node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const r=JSON.parse(d);process.exit(r.violations&&r.violations.length===0?0:1)}catch(e){process.exit(1)}})' 2>/dev/null
}
