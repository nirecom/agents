
_SETUP_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SETUP_SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$_SETUP_SCRIPT_CHECKOUT_ROOT")"
else
    _SETUP_SCRIPT_CHECKOUT_ROOT_NODE="$_SETUP_SCRIPT_CHECKOUT_ROOT"
fi
GUARD_JS="${_SETUP_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/enforce-worktree.js"
VALIDATE_SH="${_SETUP_SCRIPT_CHECKOUT_ROOT}/bin/lib/github-contents-validate.sh"
CONTENTS_WRITE_SH="${_SETUP_SCRIPT_CHECKOUT_ROOT}/bin/lib/github-contents-write.sh"
GIT_DATA_WRITE_SH="${_SETUP_SCRIPT_CHECKOUT_ROOT}/bin/lib/github-git-data-write.sh"
STEP_E_SH="${_SETUP_SCRIPT_CHECKOUT_ROOT}/skills/issue-close-finalize/scripts/step-e.sh"
COMPOSE_DOC_APPEND_BIN="${_SETUP_SCRIPT_CHECKOUT_ROOT}/bin/compose-doc-append-entry"
ISSUE_CREATE_SKILL="${_SETUP_SCRIPT_CHECKOUT_ROOT}/skills/issue-create/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'reft-positive-allow-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# bin/scan-outbound.sh reads its blocklist from AGENTS_MAIN_ROOT and fails closed (rc=4)
# without one. The write helpers point it here; the single pattern matches no fixture body.
SCAN_ROOT="$TMPDIR_BASE/scan-root"
mkdir -p "$SCAN_ROOT"
printf '%s\n' 'REFT-POSITIVE-ALLOW-SENTINEL-NEVER-IN-A-FIXTURE' > "$SCAN_ROOT/.private-info-blocklist"

# PATH is colon-separated: a C:/ entry is split at its drive colon and never searched.
path_entry() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

FIXTURES_DIR="${_SETUP_SCRIPT_CHECKOUT_ROOT}/tests/fixtures/gh-mock"
mkdir -p "$FIXTURES_DIR"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Returns 0 if allow, 1 if block.
guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Returns "<main_repo>|<wt_path>"
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# Run the enforce-worktree guard for a Bash tool. Args: command cwd [env-VAR=val ...]
run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Run the enforce-worktree guard for an Edit/Write/MultiEdit tool. Args: toolName filePath cwd [env-VAR=val ...]
run_edit_guard() {
    local tool_name="$1"; shift
    local file_path="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name: process.argv[1], tool_input:{ file_path: process.argv[2] } };
      console.log(JSON.stringify(j));
    " -- "$tool_name" "$file_path" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Inspect hook module exports. Args: name → echoes "function" or "undefined"
get_export_kind() {
    local name="$1"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        console.log(typeof m['$name']);
    " 2>/dev/null
}

require_file() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label (precondition missing: $file)"
        return 1
    fi
    return 0
}
