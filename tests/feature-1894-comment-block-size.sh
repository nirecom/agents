#!/usr/bin/env bash
# tests/feature-1894-comment-block-size.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, parser, review-cli, staged, git, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Issue #1894 — bin/review-comment-block-size: an advisory scanner that flags
# over-threshold runs of consecutive comment lines.  Origin regression: PR #1893
# landed a 10-line comment block that no existing check noticed, which is why
# the decision boundary is `run length >= T` (9 = silent, 10 = flagged).
#
# Dispatcher: shared harness + fixtures live here; the cases live in
# tests/feature-1894-comment-block-size/*.sh (rules/coding/file-split.md).
#
# Everything is driven through the CLI's contracted stdout, never through an
# internal function, so the tests stay honest about the observable contract.
#
# TL3 gap (what this test does NOT catch):
# - Anything about hooks/pre-commit: this file drives the CLI directly, and its
#   fixtures pin core.hooksPath=/dev/null. The hook seam — including a real
#   `git commit` firing the hook — is the sibling file
#   tests/feature-1894-precommit-comment-block-warn.sh (part 3).
# - Whether the installer PATH-exposes bin/review-comment-block-size so a bare
#   `review-comment-block-size` resolves on a real machine.
# - Real-world blob sizes / pack-file baselines: fixtures use loose objects only.
# - Filenames containing a newline or a character NTFS rejects (`"`, `|`, `*`):
#   those cases self-skip on Windows and are only exercised on POSIX hosts.
#   Partial exception: injection-hardening.sh reaches the STAGED path on Windows
#   too, by writing the entry straight into the index (git accepts control bytes
#   the filesystem refuses). The --all walk needs a real file, so it still
#   self-skips there.
# - Symlink traversal (including a link whose target lies outside the repo):
#   self-skips on hosts that cannot create symlinks without elevation, so the
#   `--all` walk's refusal to follow links is unverified there.
# - Temporary artifacts the scanner might write: the output/exit-code contract
#   specifies no filesystem footprint, so nothing here pins one either way.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Worktree-local copy is the state under test (rules/test/fixture-isolation.md:
# LOCAL_* vs deployed $HOME/.claude copy) — never resolve via PATH.
SCRIPT="$AGENTS_DIR/bin/review-comment-block-size"
CASE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-1894-comment-block-size"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name" "missing $(printf '%q' "$needle") in: $hay"
    fi
}

# assert_absent <name> <needle> <haystack>
assert_absent() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then
        fail "$name" "unexpected $(printf '%q' "$needle") in: $hay"
    else
        pass "$name"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
# Dual-pin: pinning only CLAUDE_WORKFLOW_DIR would still let supervisor-emit
# append into the developer's real ~/.workflow-plans/.
CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export CLAUDE_WORKFLOW_DIR WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# The three variables that can steer a verdict: the kill switch, the threshold
# and the extension list. Every invocation starts from "all three removed from
# the child environment" and then re-pins only what the case is about, so
# neither the ambient shell nor the developer's .env can decide an outcome
# (test-design.md "Config-dependent branches"). The file-count and byte-size
# caps are compiled-in constants with no env knob — config-numeric-caps.sh
# pins both their boundaries and their non-configurability.
CB_ENV_RESET=(
    -u COMMENT_BLOCK_WARN
    -u COMMENT_BLOCK_WARN_LINES
    -u CODE_FILE_EXTENSIONS
)
BASE_ENV=(
    "COMMENT_BLOCK_WARN_LINES=10"
    "CODE_FILE_EXTENSIONS=js;sh;py"
)
# A comment body planted in fixture files. The output contract reports paths,
# line ranges and counts only, so this string must never reach stdout/stderr.
SENTINEL='SENTINEL-DO-NOT-LEAK-abc123'

# Config is appended to .git/config rather than set through four `git config`
# processes: this suite builds ~15 fixture repos and process spawn dominates
# its runtime on Windows.
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

# A fixture repo with one committed README so HEAD exists.
new_repo() {
    local dir="$TMPDIR_BASE/$1"
    init_repo "$dir"
    echo "init" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
    printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# render_spec <spec> — mini-DSL that expands a whitespace-separated token list
# into file content, one line per token:
#   _            -> an empty line
#   ^            -> a space inside a token ("*^a" -> "* a")
#   <body>*<N>   -> <body> repeated N times
# Globbing is disabled while splitting so tokens like "*)" survive verbatim.
# ---------------------------------------------------------------------------
render_spec() {
    local spec="$1" tok body count i
    set -f
    # shellcheck disable=SC2086
    for tok in $spec; do
        body="$tok"
        count=1
        if [[ "$tok" =~ ^(.*)\*([0-9]+)$ ]]; then
            body="${BASH_REMATCH[1]}"
            count="${BASH_REMATCH[2]}"
        fi
        [ "$body" = "_" ] && body=""
        body="${body//^/ }"
        for ((i = 0; i < count; i++)); do printf '%s\n' "$body"; done
    done
    set +f
}

# ---------------------------------------------------------------------------
# run_cb <repo> [VAR=VAL ...] -- [cli args ...]
# Sets CB_OUT (stdout), CB_ERR (stderr), CB_RC.
# ---------------------------------------------------------------------------
CB_OUT=""
CB_ERR=""
CB_RC=0
run_cb() {
    local repo="$1"; shift
    local -a envs=("${CB_ENV_RESET[@]}" "${BASE_ENV[@]}")
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    local errfile="$TMPDIR_BASE/cb.err"
    CB_RC=0
    CB_OUT="$( (cd "$repo" && run_with_timeout 60 env "${envs[@]}" bash "$SCRIPT" "$@") 2>"$errfile" )" || CB_RC=$?
    CB_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

cb_header() { printf '%s\n' "$CB_OUT" | head -1; }

# The staged-side run length reported by the first finding line, or "none".
# Handles both contracted shapes:
#   ... longest comment run 12 → 23 lines (over-threshold runs 1 → 2)
#   ... longest comment run 23 lines (no baseline: absolute-state fallback)
# i.e. always the last number before " lines".
cb_longest() {
    local line n
    line="$(printf '%s\n' "$CB_OUT" | grep -m1 'longest comment run ' || true)"
    if [ -z "$line" ]; then printf 'none'; return; fi
    n="$(printf '%s\n' "$line" | sed -n 's/^.*[^0-9]\([0-9][0-9]*\) lines.*$/\1/p')"
    if [ -z "$n" ]; then printf 'unparsed:%s' "$line"; else printf '%s' "$n"; fi
}

cb_warn_count() { printf '%s\n' "$CB_OUT" | grep -c '^WARN: ' || true; }

# ============================================================================
# Cases
# ============================================================================
# shellcheck source=./feature-1894-comment-block-size/scanner-core.sh
. "$CASE_DIR/scanner-core.sh"
# shellcheck source=./feature-1894-comment-block-size/staged-regression.sh
. "$CASE_DIR/staged-regression.sh"
# shellcheck source=./feature-1894-comment-block-size/degenerate-fallback.sh
. "$CASE_DIR/degenerate-fallback.sh"
# shellcheck source=./feature-1894-comment-block-size/output-contract.sh
. "$CASE_DIR/output-contract.sh"
# shellcheck source=./feature-1894-comment-block-size/scan-scope-and-leak.sh
. "$CASE_DIR/scan-scope-and-leak.sh"
# shellcheck source=./feature-1894-comment-block-size/special-paths.sh
. "$CASE_DIR/special-paths.sh"
# shellcheck source=./feature-1894-comment-block-size/hostile-content.sh
. "$CASE_DIR/hostile-content.sh"
# shellcheck source=./feature-1894-comment-block-size/injection-hardening.sh
. "$CASE_DIR/injection-hardening.sh"
# shellcheck source=./feature-1894-comment-block-size/config-hostility.sh
. "$CASE_DIR/config-hostility.sh"
# shellcheck source=./feature-1894-comment-block-size/config-numeric-caps.sh
. "$CASE_DIR/config-numeric-caps.sh"
# shellcheck source=./feature-1894-comment-block-size/injection-execution.sh
. "$CASE_DIR/injection-execution.sh"
# shellcheck source=./feature-1894-comment-block-size/baseline-precedence.sh
. "$CASE_DIR/baseline-precedence.sh"
# shellcheck source=./feature-1894-comment-block-size/escaper-placement-static.sh
. "$CASE_DIR/escaper-placement-static.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
