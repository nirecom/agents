# shellcheck shell=bash
# tests/TL3-skill-worktree-start-auto-naming/helpers.sh
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, helpers, fixture, claude-e2e, TL3, scope:common
#
# Sourced by ../TL3-skill-worktree-start-auto-naming.sh — assumes AGENTS_DIR,
# pass() and fail() are already defined. Not a standalone runner.

# The dispatcher runs under `set -e`; a case that probes an expected non-zero
# exit must not abort the whole file. Keep nounset, drop errexit.
set +e

WS_SCRIPT="$AGENTS_DIR/skills/worktree-start/scripts/derive-worktree-name.sh"
WS_CLEANUP=""
# shellcheck disable=SC2064  # expand WS_CLEANUP at trap time, not at set time
trap 'for d in $WS_CLEANUP; do rm -rf "$d"; done' EXIT

# run_with_timeout <secs> <command...> — portable (macOS has no coreutils timeout).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# native_path <path> — the spelling git itself prints for a path. A mktemp path
# is MSYS-style (/tmp/...) under Git Bash while `git worktree list --porcelain`
# reports C:/..., so the two are not comparable until one side is translated.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# norm_path <path> — the WS-2 comparison normalization: backslashes to slashes,
# trailing slash dropped, lowercased (both host filesystems here are
# case-insensitive for the directory names this fixture builds).
norm_path() {
    printf '%s' "$1" | tr '\\' '/' | sed 's#/*$##' | tr 'A-Z' 'a-z'
}

# ws_setup <tag> — build an isolated fixture and export the pinned environment.
#
# Fixture isolation (rules/test/fixture-isolation.md): CLAUDE_WORKFLOW_DIR and
# WORKFLOW_PLANS_DIR are dual-pinned, the private-repo cache is declared so no
# run reaches `gh repo list`, and WORKTREE_BASE_DIR is exported — process env
# wins over .env in bin/get-config-var, so the model's own lookup resolves to
# the fixture base rather than the developer's real worktree root.
ws_setup() {
    local tag="$1"
    WS_BASE="$(mktemp -d)"
    WS_CLEANUP="$WS_CLEANUP $WS_BASE"
    WS_REPO="$WS_BASE/sample-repo"
    WS_WT="$WS_BASE/wt"
    WS_PROBE_LOG="$WS_BASE/askuserquestion-was-called.log"
    mkdir -p "$WS_REPO/.claude/skills" "$WS_WT" "$WS_BASE/wf" "$WS_BASE/plans"

    git -C "$WS_REPO" init -q
    git -C "$WS_REPO" config core.hooksPath /dev/null
    git -C "$WS_REPO" config user.email "test@example.com"
    git -C "$WS_REPO" config user.name "Test"
    printf '# %s\n' "$tag" > "$WS_REPO/README.md"
    git -C "$WS_REPO" add README.md
    git -C "$WS_REPO" commit -qm "init"

    cp -r "$AGENTS_DIR/skills/worktree-start" "$WS_REPO/.claude/skills/worktree-start"

    # AskUserQuestion probe: a PreToolUse hook that records the call and denies
    # it. Absence of the log file is the assertion "the model never asked".
    cat > "$WS_BASE/askprobe.js" <<'PROBE_EOF'
const fs = require("fs");
fs.appendFileSync(process.env.WS_PROBE_LOG, "AskUserQuestion invoked\n");
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "TL3 probe: worktree-start must never ask for a task name or branch type.",
  },
}));
PROBE_EOF

    # Minimal settings.json: only the probe hook. No disableBypassPermissionsMode
    # (it would neutralize --dangerously-skip-permissions and hang the run).
    cat > "$WS_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          { "type": "command", "command": "node \"$(native_path "$WS_BASE/askprobe.js")\"", "timeout": 10 }
        ]
      }
    ]
  }
}
SETTINGS_EOF

    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export WORKTREE_BASE_DIR="$WS_WT"
    export CLAUDE_WORKFLOW_DIR="$WS_BASE/wf"
    export WORKFLOW_PLANS_DIR="$WS_BASE/plans"
    export WS_PROBE_LOG
    export PRIVATE_REPO_NAMES_CACHE_SET=1
    export PRIVATE_REPO_NAMES_CACHE=''
}

# ws_claude <session-id> <prompt> — one real `claude -p` turn in the fixture repo.
# Sets WS_OUT and WS_RC.
ws_claude() {
    local sid="$1" prompt="$2"
    WS_OUT="$(
        cd "$WS_REPO" &&
        unset CLAUDECODE &&
        CLAUDE_CODE_SESSION_ID="$sid" \
        run_with_timeout 180 claude -p "$prompt" \
            --session-id "$sid" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format text \
        2>&1
    )"
    WS_RC=$?
}

# ws_derive <session-id> [args...] — the oracle: the very script WS-2 runs,
# invoked directly with the same repo, same session id and same pinned env.
# Sets WS_TASK, WS_BRANCH_TYPE, WS_REPO_NAME, WS_DERIVE_RC.
ws_derive() {
    local sid="$1"; shift
    local out
    out="$(cd "$WS_REPO" && CLAUDE_CODE_SESSION_ID="$sid" bash "$WS_SCRIPT" "$@" </dev/null 2>&1)"
    WS_DERIVE_RC=$?
    WS_TASK="$(printf '%s\n' "$out" | sed -n 's/^TASK_NAME=//p' | head -1)"
    WS_BRANCH_TYPE="$(printf '%s\n' "$out" | sed -n 's/^BRANCH_TYPE=//p' | head -1)"
    WS_REPO_NAME="$(printf '%s\n' "$out" | sed -n 's/^REPO_NAME=//p' | head -1)"
    WS_DERIVE_OUT="$out"
}

# ws_worktree_count — registered worktrees, main checkout included.
ws_worktree_count() {
    git -C "$WS_REPO" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true
}

# ws_branch_of <normalized-path> — the `branch` line of the linked worktree at
# that path, or the empty string when no entry matches.
ws_branch_of() {
    local want="$1" line cur=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) cur="$(norm_path "${line#worktree }")" ;;
            "branch "*)   [ "$cur" = "$want" ] && { printf '%s' "${line#branch }"; return 0; } ;;
        esac
    done < <(git -C "$WS_REPO" worktree list --porcelain 2>/dev/null)
    printf ''
}

# ws_assert_no_prompt <label> — the non-interactivity assertion.
ws_assert_no_prompt() {
    if [ -f "$WS_PROBE_LOG" ]; then
        fail "$1 AskUserQuestion was invoked during the run — WS-2 must never ask (probe log: $(cat "$WS_PROBE_LOG"))"
    else
        pass "$1 no AskUserQuestion tool call reached the host — the naming path stayed non-interactive"
    fi
}

# The prompt both cases share. WS-1 is pre-satisfied and the run is stopped
# after WS-6 so no worker fleet or EnterWorktree tool is needed. The expected
# task name and branch type are deliberately NOT mentioned — the model has to
# obtain them from the script, which is the whole point of the seam.
ws_prompt() {
    local extra="$1"
    cat <<PROMPT_EOF
Read the file .claude/skills/worktree-start/SKILL.md in the current directory and
execute its procedure for this repository, with these adjustments:
- WS-1 is already satisfied; do not re-evaluate it.
- ${extra}
- WORKTREE_BASE_DIR is already set in your shell environment; use its value.
- Stop after WS-6. Do NOT perform WS-7, WS-8 or WS-9.
Use the Bash tool for every command. Do not invent a task name or branch type.
PROMPT_EOF
}
