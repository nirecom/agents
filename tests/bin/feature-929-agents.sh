#!/bin/bash
# tests/feature-929-agents.sh
# Tests: bin/supervisor-findings-codex, hooks/lib/supervisor-codex-parse.js, hooks/workflow-state/state-io/core.js, hooks/session-start.js, bin/supervisor-write-audit-verdict, hooks/lib/supervisor-state-writer/audit-run.js
# Tags: supervisor, em-supervisor, codex, audit, alert, transcript, parser, atomic-write, TL2, scope:issue-specific
#
# #929 EM Supervisor audit mode accuracy — Codex engine + review layer.
# Dispatcher for the split folder tests/feature-929-agents/.

set -u

# RED PHASE (TDD): write-code has NOT run, so cases targeting not-yet-created
# sources or not-yet-applied changes are EXPECTED to FAIL on assertions; each
# fragment marks them `# NOTE: RED until ...`. The dispatcher's own obligation is
# HARNESS SOUNDNESS: run, source every fragment, fail cleanly (never hang).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
to_node_path() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
_AGENTS_DIR_NODE="$(to_node_path "$AGENTS_DIR")"

# Sources under test.
CORE_JS="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io/core.js"
SESSION_START_JS="$_AGENTS_DIR_NODE/hooks/session-start.js"
WORKFLOW_STATE_JS="$_AGENTS_DIR_NODE/hooks/workflow-state"
FINDINGS_CLI="$AGENTS_DIR/bin/supervisor-findings-codex"
PARSE_MODULE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-codex-parse.js"
WRITE_AUDIT_CLI="$AGENTS_DIR/bin/supervisor-write-audit-verdict"
AUDIT_RUN_JS="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer/audit-run.js"
SCHEMA_JS="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

# Codex output markers reused across fixtures (SSOT: hooks/lib/codex-review-parse.js).
CODEX_BEGIN="<!-- begin-codex-output -->"
CODEX_END="<!-- end-codex-output -->"
CODEX_PERFORMED_LABEL="## codex-review: PERFORMED"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Portable timeout wrapper (macOS/CI have no `timeout` by default). Default 120s.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name — expected to contain '$needle', got: $(printf '%.200s' "$haystack")" ;;
    esac
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) fail "$name — expected NOT to contain '$needle', got: $(printf '%.200s' "$haystack")" ;;
        *) pass "$name" ;;
    esac
}

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin dirs, unset session IDs.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"

WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

EMPTY_TRANSCRIPT_DIR="$TMPDIR_BASE/transcripts-empty"
mkdir -p "$EMPTY_TRANSCRIPT_DIR"
export CLAUDE_TRANSCRIPT_BASE_DIR="$EMPTY_TRANSCRIPT_DIR"

unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_ENV_FILE 2>/dev/null || true

# Deterministic codex-absence PATH (portable: Git Bash + Linux CI).
# codex-core.sh detects the CLI with `command -v codex`; to force absence WITHOUT
# losing `node` (both share the fnm dir here) we expose a shim dir holding only a
# `node` wrapper plus /usr/bin:/bin. The entry must be POSIX-form (/c/... not
# C:/...) or MSYS won't search it — hence cygpath -u.
CODEX_SHIM_DIR="$TMPDIR_BASE/codex-absent-shim"
_build_codex_shim() {
    rm -rf "$CODEX_SHIM_DIR"
    mkdir -p "$CODEX_SHIM_DIR"
    local real_node
    real_node="$(command -v node)"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_node" > "$CODEX_SHIM_DIR/node"
    chmod +x "$CODEX_SHIM_DIR/node"
}
_build_codex_shim
codex_absent_path() {
    local shim_posix="$CODEX_SHIM_DIR"
    if command -v cygpath >/dev/null 2>&1; then shim_posix="$(cygpath -u "$CODEX_SHIM_DIR")"; fi
    echo "$shim_posix:/usr/bin:/bin"
}

# Fixture repo with git-native hooks disabled (fixture-isolation.md).
setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    echo "$repo"
}

# TL3 gap: these TL2 fragments force codex ABSENT (STATUS: SKIPPED) or drive a
# capturing codex SHIM (deterministic PROMPT/OUTFILE). What only a real codex CLI
# on a CI host exercises — actual `codex exec` latency/exit codes, genuine
# STATUS: SUCCESS end-to-end (alert ingest + audit verdict/findings write), and
# native os.tmpdir readback across win/posix — is left to the RUN_TL3-gated
# TL3- E2E (rules/test/claude-e2e.md). Run that on a native host before release.

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-929-agents"

# case_begin / case_end — logical group markers for check-case-markers (RT-1b).
# This dispatcher uses its own pass/fail/skip counters; case_begin only logs.
case_begin() { echo "--- group: $1 ---"; }
case_end()   { :; }

case_begin "transcript-persist" "hooks/session-start.js"
# shellcheck source=./feature-929-agents/transcript-persist.sh
. "$SCRIPT_DIR/transcript-persist.sh"
case_end

case_begin "findings-codex-status" "bin/supervisor-findings-codex"
# shellcheck source=./feature-929-agents/findings-codex-status.sh
. "$SCRIPT_DIR/findings-codex-status.sh"
case_end

case_begin "codex-parse" "hooks/lib/supervisor-codex-parse.js"
# shellcheck source=./feature-929-agents/codex-parse.sh
. "$SCRIPT_DIR/codex-parse.sh"
case_end

case_begin "audit-atomic-write" "hooks/lib/supervisor-state-writer/audit-run.js"
# shellcheck source=./feature-929-agents/audit-atomic-write.sh
. "$SCRIPT_DIR/audit-atomic-write.sh"
case_end

case_begin "audit-subcheck-prompt" "bin/supervisor-write-audit-verdict"
# shellcheck source=./feature-929-agents/audit-subcheck-prompt.sh
. "$SCRIPT_DIR/audit-subcheck-prompt.sh"
case_end

case_begin "dual-id" "hooks/workflow-state/state-io/core.js"
# shellcheck source=./feature-929-agents/dual-id.sh
. "$SCRIPT_DIR/dual-id.sh"
case_end

echo ""
echo "=== Results (feature-929-agents) ==="
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
