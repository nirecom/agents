#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, hook, git, advisory, guard, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Issue #1894 — the hooks/pre-commit WARN section for review-comment-block-size.
#
# Why this section is different from every other block in the hook: it is purely
# advisory. It must never change any commit's exit code — not when it finds
# something, not when the scanner itself falls over. That makes four properties
# load-bearing, and they are tested separately (CPR-SC):
#   (1) the two-condition AND guard decides whether the section runs at all;
#   (2) the section is placed BEFORE the hook's three unconditional early exits
#       (non-GitHub remote / private repo / empty index), or it would never run
#       for the repos that actually matter;
#   (3) the section contains no `exit`, and pre-initialises _cb_out/_cb_rc so
#       `set -euo pipefail` cannot abort the hook on the success path;
#   (4) a REAL `git commit` carrying findings still lands (part 3).
#
# Dispatcher: shared harness + fixtures live here; cases live in
# tests/feature-1894-precommit-comment-block-warn/*.sh (rules/coding/file-split.md).
#
# TL3 gap (what this test does NOT catch):
# - Whether the installer deploys the updated hook into a real machine's
#   core.hooksPath. Part 3 proves git fires the hook, but only for a fixture
#   repo whose hooksPath this test points at itself.
# - Real `gh api` repo-visibility resolution: the private-repo early exit is
#   represented here by its non-GitHub-remote sibling, which needs no network.
# - Interaction with the Claude Code PreToolUse hook chain (enforce-worktree,
#   workflow-gate): fixtures pin ENFORCE_WORKTREE=off.
# - Whether rules/coding/file-split.md renders as the installed rule a session
#   actually loads: part 2's S3/S3b read the worktree file as text.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The worktree copy is the state under test — never the deployed ~/.claude one.
PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"
LOCAL_SCANNER="$AGENTS_DIR/bin/review-comment-block-size"
FILE_SPLIT_RULE="$AGENTS_DIR/rules/coding/file-split.md"
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1894-precommit-comment-block-warn"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then pass "$name"
    else fail "$name" "missing $(printf '%q' "$needle") in: $hay"; fi
}
assert_absent() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then
        fail "$name" "unexpected $(printf '%q' "$needle") in: $hay"
    else pass "$name"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$PRECOMMIT" ]; then
    echo "FAIL: hooks/pre-commit not found at $PRECOMMIT"
    exit 1
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin both dirs and
# drop any inherited session id so the hook cannot touch real session state.
CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export CLAUDE_WORKFLOW_DIR WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

WARN_LINE='WARN: sample.js — longest comment run 10 → 23 lines (over-threshold runs 1 → 2)'
SCANNER_HEADER='## Comment-block Size Review: PERFORMED (staged mode)'
ERR_LINE='ERROR: sample.js — baseline blob unreadable'
ADVISORY_NOTICE='pre-commit: comment-block warnings are advisory — commit continues.'
# Planted in the comment body of a scanned file. The output contract reports
# paths, line ranges and counts only — never comment text — so this string must
# never surface on stdout or stderr.
SENTINEL='SENTINEL-DO-NOT-LEAK-abc123'

# Every stub records the argv it was called with, so a hook that invokes the
# scanner with the wrong mode (or not at all) cannot pass silently.
STUB_PROLOGUE='_argv_log="$(dirname "$0")/../.scanner-argv"; { printf "%s\n" "$#"; if [ $# -gt 0 ]; then printf "%s\n" "$@"; fi; } > "$_argv_log"'

# write_stub <path> <kind>
#   warn  -> contracted output containing ^WARN: lines, rc 0
#   clean -> contracted output with no ^WARN: line, rc 0
#   rc3   -> internal-error output, rc 3
#   real  -> thin wrapper around the worktree's real scanner
write_stub() {
    local path="$1" kind="$2"
    case "$kind" in
        warn)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
echo ""
echo "Staged code files scanned: 1 (extensions: js;sh;py; threshold: >= 10 consecutive comment lines)"
echo "$WARN_LINE"
echo "  L10-L32 (23 lines)"
echo ""
echo "  WARN findings are advisory only — this check never blocks a commit."
exit 0
EOF
            ;;
        clean)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
echo ""
echo "Staged code files scanned: 1 (extensions: js;sh;py; threshold: >= 10 consecutive comment lines)"
exit 0
EOF
            ;;
        rc3)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
echo "$ERR_LINE"
exit 3
EOF
            ;;
        real)
            { printf '#!/usr/bin/env bash\n'
              printf '%s\n' "$STUB_PROLOGUE"
              printf 'exec bash "%s" "$@"\n' "$LOCAL_SCANNER"
            } > "$path"
            ;;
    esac
    chmod +x "$path" 2>/dev/null || true
}

# scanner_argc / scanner_argv <config-repo> — what the hook actually passed.
scanner_argc() {
    local f="$1/.scanner-argv"
    if [ ! -f "$f" ]; then printf 'not-invoked'; return; fi
    head -1 "$f"
}
scanner_argv() {
    local f="$1/.scanner-argv"
    if [ ! -f "$f" ]; then printf 'not-invoked'; return; fi
    sed -n '2,$p' "$f" | tr '\n' ' ' | sed 's/ *$//'
}

# core.hooksPath=/dev/null neutralises the developer's installed hooks
# (rules/test/fixture-isolation.md). Cases that need git to fire the hook under
# test override it per command with `git -c core.hooksPath=<dir>` — see part 3.
# Written straight into .git/config: four `git config` spawns per fixture repo
# is a measurable share of this suite's runtime on Windows.
init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    cat >> "$dir/.git/config" <<'CFG'
[user]
	email = test@example.com
	name = Test
[core]
	hooksPath = /dev/null
	autocrlf = false
CFG
}

# make_repo <name> <scanner-kind> [remote]
#   scanner-kind: warn | clean | rc3 | real | none | noexec
#   remote: "none" (default) or a URL
make_repo() {
    local name="$1" kind="$2" remote="${3:-none}"
    local dir="$TMPDIR_BASE/$name"
    init_repo "$dir"
    mkdir -p "$dir/bin"
    case "$kind" in
        none) : ;;
        noexec)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/review-comment-block-size"
            chmod 000 "$dir/bin/review-comment-block-size" 2>/dev/null || true
            ;;
        *) write_stub "$dir/bin/review-comment-block-size" "$kind" ;;
    esac
    echo "init" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
    [ "$remote" != "none" ] && git -C "$dir" remote add origin "$remote"
    printf '%s' "$dir"
}

# make_hooks_dir <name> — a core.hooksPath directory whose pre-commit is the
# worktree hook under test.
make_hooks_dir() {
    local dir="$TMPDIR_BASE/$1"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nexec bash "%s"\n' "$PRECOMMIT" > "$dir/pre-commit"
    chmod +x "$dir/pre-commit"
    printf '%s' "$dir"
}

# A staged .js file (not .sh: the hook's execute-bit check runs earlier and
# would block on a mode-100644 shell script before reaching the new section).
stage_sample() {
    local repo="$1" body="${2:-note}"
    { echo "var x = 1;"
      for i in $(seq 1 12); do echo "// $body $i"; done
    } > "$repo/sample.js"
    git -C "$repo" add sample.js
}

# The three variables that can steer a verdict: the kill switch, the threshold
# and the extension list. Every invocation starts from "all removed" and then
# re-pins only what the case is about, so the ambient shell/.env can never
# decide an outcome (test-design.md "Config-dependent branches").
CB_ENV_RESET=(
    -u COMMENT_BLOCK_WARN
    -u COMMENT_BLOCK_WARN_LINES
    -u CODE_FILE_EXTENSIONS
)

OUT=""
ERR=""
RC=0
# run_precommit <repo> <agents-config-dir> [VAR=VAL ...]
run_precommit() {
    local repo="$1" cfg="$2"; shift 2
    local errfile="$TMPDIR_BASE/pc.err"
    RC=0
    OUT="$( (cd "$repo" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 60 env "${CB_ENV_RESET[@]}" \
            "AGENTS_CONFIG_DIR=$cfg" \
            "ENFORCE_WORKTREE=off" \
            "COMMENT_BLOCK_WARN_LINES=10" \
            "CODE_FILE_EXTENSIONS=js;sh;py" \
            "$@" \
            bash "$PRECOMMIT") 2>"$errfile" )" || RC=$?
    ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# run_commit <repo> <agents-config-dir> <hooks-dir> <message> [VAR=VAL ...]
# A real `git commit` — git decides whether to fire the hook and whether the
# hook's exit code blocks the commit.
run_commit() {
    local repo="$1" cfg="$2" hooks="$3" msg="$4"; shift 4
    RC=0
    OUT="$( (cd "$repo" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 60 env "${CB_ENV_RESET[@]}" \
            "AGENTS_CONFIG_DIR=$cfg" \
            "ENFORCE_WORKTREE=off" \
            "COMMENT_BLOCK_WARN_LINES=10" \
            "CODE_FILE_EXTENSIONS=js;sh;py" \
            "$@" \
            git -c "core.hooksPath=$hooks" commit -q -m "$msg") 2>&1 )" || RC=$?
    ERR=""
}

NON_GITHUB="https://git.example.com/acme/widgets.git"

# ============================================================================
# Cases
# ============================================================================
# shellcheck source=feature-1894-precommit-comment-block-warn/guard-and-killswitch.sh
. "$CASE_DIR/guard-and-killswitch.sh"
# shellcheck source=feature-1894-precommit-comment-block-warn/failopen-placement-static.sh
. "$CASE_DIR/failopen-placement-static.sh"
# shellcheck source=feature-1894-precommit-comment-block-warn/commit-integration.sh
. "$CASE_DIR/commit-integration.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
