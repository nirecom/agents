# tests/feature-1180-commit-lang-check/lib.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, scope:issue-specific
#
# Shared harness for the feature-1180-commit-lang-check dispatcher.
# Sourced by tests/feature-1180-commit-lang-check.sh — not executable standalone.
# Provides: AGENTS_DIR, LINT_LIB(_NODE), LANG_BLOCK_MARKER, PASS/FAIL counters,
# TMPDIR_BASE (+ EXIT trap), and the pass/fail/run_with_timeout/require_sut/
# make_git_repo/run_precommit/run_check_node/run_check_node_raw/
# json_violations_empty helpers.

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

# --- CODE_LANG_EXCLUDE test isolation (single point of enforcement) ----------
# Any helper call that does not itself decide CODE_LANG_EXCLUDE gets this value
# injected automatically. Rationale: hooks/lib/load-env.js treats an empty
# process.env value as UNSET and lets the host's real .env supply one, so a
# developer machine carrying a genuine CODE_LANG_EXCLUDE could silently flip
# block/allow assertions in every case that never mentions the variable.
# Passing "" would NOT fix that — only a NON-EMPTY value wins over .env.
# The value below is an absolute path that cannot exist and cannot cover any
# repo root, so injecting it is behaviourally inert while pinning the variable.
EXCLUDE_ISOLATION_SENTINEL="/__cle-isolation-sentinel-never-matches__"

# Pseudo-argument for the few cases that deliberately source CODE_LANG_EXCLUDE
# from a stubbed .env (the sentinel would override it). Pass it in place of a
# CODE_LANG_EXCLUDE= assignment; the helpers strip it before calling `env`.
EXCLUDE_FROM_DOTENV="@exclude-from-dotenv@"

# _isolate_exclude_env <arg...> — echoes nothing; rebuilds the global array
# _ISOLATED_ENV_ARGS from "$@", stripping $EXCLUDE_FROM_DOTENV and prepending
# CODE_LANG_EXCLUDE=$EXCLUDE_ISOLATION_SENTINEL unless the caller already
# decided the variable (a `CODE_LANG_EXCLUDE=...` assignment, a bare
# `CODE_LANG_EXCLUDE` operand of `env -u`, or the opt-out marker).
_ISOLATED_ENV_ARGS=()
_isolate_exclude_env() {
    local a decided=no
    _ISOLATED_ENV_ARGS=()
    for a in "$@"; do
        case "$a" in
            "$EXCLUDE_FROM_DOTENV") decided=yes; continue ;;
            CODE_LANG_EXCLUDE=*|CODE_LANG_EXCLUDE) decided=yes ;;
        esac
        _ISOLATED_ENV_ARGS+=("$a")
    done
    if [ "$decided" = no ]; then
        _ISOLATED_ENV_ARGS=("CODE_LANG_EXCLUDE=$EXCLUDE_ISOLATION_SENTINEL" \
            ${_ISOLATED_ENV_ARGS[@]+"${_ISOLATED_ENV_ARGS[@]}"})
    fi
}

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
# CODE_LANG_EXCLUDE is auto-isolated (see _isolate_exclude_env) unless the
# caller passes it explicitly or opts out with $EXCLUDE_FROM_DOTENV.
PC_RC=0
run_precommit() {
    local repo="$1"; shift
    _isolate_exclude_env "$@"
    PC_RC=0
    local out
    out="$( (cd "$repo" && run_with_timeout 30 env "${_ISOLATED_ENV_ARGS[@]}" bash "$AGENTS_DIR/hooks/pre-commit") 2>&1 )" || PC_RC=$?
    printf '%s' "$PC_RC" > "$TMPDIR_BASE/.last_pc_rc"
    echo "$out"
}

# Node driver source shared by run_check_node / run_check_node_raw: require the
# real LINT_LIB and print check()'s JSON. check() is called with NO args (matches
# the production call site in hooks/pre-commit). Exceptions are deliberately NOT
# caught — run_check_node_raw relies on them producing a non-zero exit code.
CHECK_NODE_SRC="
        const m = require('$LINT_LIB_NODE');
        process.stdout.write(JSON.stringify(m.check()));
    "

# Run the check() driver with process.cwd() = the temp git repo. AGENTS_CONFIG_DIR
# points at the real repo (where the module lives); CODE_LANG is passed as a
# direct env var (wins over real .env).
# Args: $1=repo, $2=CODE_LANG value (may be empty), $3=CODE_LANG_EXCLUDE (OPTIONAL).
# When $3 is omitted, $EXCLUDE_ISOLATION_SENTINEL is injected instead: a
# never-matching absolute path that is behaviourally identical to "no exclude"
# while making the case immune to a real CODE_LANG_EXCLUDE in the host's .env.
# Passing "" would NOT mean "empty": per hooks/lib/load-env.js an empty
# process.env value is treated as unset and is overwritten by .env — cases that
# need a genuinely empty value must stub AGENTS_CONFIG_DIR instead (see X11).
# Prints check() JSON; stderr discarded.
run_check_node() {
    local repo="$1" lang="$2"
    local excl="$EXCLUDE_ISOLATION_SENTINEL"
    [ "$#" -ge 3 ] && excl="$3"
    (cd "$repo" && run_with_timeout 15 env \
        CODE_LANG="$lang" \
        CODE_LANG_EXCLUDE="$excl" \
        AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        node -e "$CHECK_NODE_SRC" 2>/dev/null)
}

# Same driver, but stderr is PRESERVED (merged into stdout) and the node exit
# code is recorded — required by cases that assert on a thrown exception's
# message and on the non-zero exit that lets hooks/pre-commit fail open.
# Args: $1=cwd (need not be a git repo), remaining args are passed verbatim to
# `env` (KEY=VAL assignments and/or flags such as `-u NAME`).
# CODE_LANG_EXCLUDE is auto-isolated (see _isolate_exclude_env) unless the caller
# decides it — `-u CODE_LANG_EXCLUDE` counts as deciding it.
# Sets CN_RC and writes it to $TMPDIR_BASE/.last_cn_rc (read the file when the
# call is made inside a command substitution — the subshell cannot export CN_RC).
CN_RC=0
run_check_node_raw() {
    local cwd="$1"; shift
    _isolate_exclude_env "$@"
    CN_RC=0
    local out
    out="$( (cd "$cwd" && run_with_timeout 15 env "${_ISOLATED_ENV_ARGS[@]}" node -e "$CHECK_NODE_SRC") 2>&1 )" || CN_RC=$?
    printf '%s' "$CN_RC" > "$TMPDIR_BASE/.last_cn_rc"
    printf '%s' "$out"
}

# Assert result JSON has zero violations. Reads JSON on stdin, exits 0 if empty.
json_violations_empty() {
    node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const r=JSON.parse(d);process.exit(r.violations&&r.violations.length===0?0:1)}catch(e){process.exit(1)}})' 2>/dev/null
}
