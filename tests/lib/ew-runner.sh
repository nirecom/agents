#!/usr/bin/env bash
# tests/lib/ew-runner.sh
# Tests: hooks/enforce-worktree.js
# Tags: TL1, shared-lib, scope:permanent
# End-to-end runner for hooks/enforce-worktree.js shared by the #2393 D-H test
# files. Source AFTER tests/lib/harness.sh (needs np, run_with_timeout).
# The hook resolves the repo from the real process CWD, so ew_run cd's into it.

EW_GUARD="$(np "$AGENTS_DIR/hooks/enforce-worktree.js")"

# ew_make_repo <dir> — main-branch repo with one commit; hooks disabled per
# rules/test/fixture-isolation.md.
ew_make_repo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test"
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config core.autocrlf false
    echo "init" > "$1/README.md"
    git -C "$1" add README.md
    git -C "$1" commit -q -m "initial"
}

# ew_bash_payload <session_id> <command>
ew_bash_payload() {
    node -e "process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:'Bash',tool_input:{command:process.argv[2]}}))" "$1" "$2"
}

# ew_write_payload <session_id> <tool_name> <file_path>
ew_write_payload() {
    node -e "process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:process.argv[2],tool_input:{file_path:process.argv[3],content:'x'}}))" "$1" "$2" "$3"
}

# ew_run <cwd> <payload> [KEY=VAL...] → allow | block | timeout | crash:<rc> | other:<out>
# AGENTS_CONFIG_DIR defaults to EW_CONFIG_DIR (a fixture) so the real .env is never
# read; callers' KEY=VAL pairs come last and therefore win.
ew_run() {
    local cwd="$1" payload="$2"; shift 2
    local out rc=0
    out="$(cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SCRATCHPAD -u DEFAULT_BRANCHES \
        -u ENFORCE_WORKTREE_ADDITIONAL_REPOS -u WORKFLOW_OFF \
        ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=${EW_CONFIG_DIR:?EW_CONFIG_DIR unset}" \
        "$@" node "$EW_GUARD" 2>/dev/null)" || rc=$?
    out="$(printf '%s' "$out" | tr -d '\r\n')"
    case "$rc" in
        0) ;;
        124) printf 'timeout'; return ;;
        *) printf 'crash:%s' "$rc"; return ;;
    esac
    case "$out" in
        '{}') printf 'allow' ;;
        *'"decision":"block"'*) printf 'block' ;;
        *) printf 'other:%s' "$out" ;;
    esac
}

# ew_raw <cwd> <payload> [KEY=VAL...] — the hook's raw stdout (for reason checks).
ew_raw() {
    local cwd="$1" payload="$2"; shift 2
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SCRATCHPAD -u DEFAULT_BRANCHES \
        -u ENFORCE_WORKTREE_ADDITIONAL_REPOS -u WORKFLOW_OFF \
        ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=${EW_CONFIG_DIR:?EW_CONFIG_DIR unset}" \
        "$@" node "$EW_GUARD" 2>/dev/null) || true
}

# ew_expect <allow|block> <label> <actual>
ew_expect() {
    if [[ "$3" == "$1" ]]; then pass "$2"; else fail "$2" "want=$1 got=$3"; fi
}
