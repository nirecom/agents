#!/bin/bash
# tests/bin/feature-review-code-codex/_lib.sh — sourced by the feature-review-code-codex*.sh entrypoints; NOT a test file.
# Fixtures + helpers shared by every entrypoint (#2723 split). The entrypoint sets AGENTS_ROOT first.

SCRIPT="$AGENTS_ROOT/bin/review-code-codex"
ERRORS=0

# Quiet case markers for the entrypoints (the textual case-marker gate wants them; this lib does not load the harness).
case_begin() { :; }
case_end() { :; }

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Setup: temp git repo with a commit on a branch vs main
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md). The cap-threshold rows below assert
# behaviour against the built-in CODEX_REVIEW_MAX_DIFF_LINES default of 5000. Without isolation
# they inherit the developer's real AGENTS_MAIN_ROOT, whose .env load-env.js loads; a
# relaxed cap there (e.g. 10000) silently lets an over-cap diff through, so every TRUNCATED row
# fails on that machine while passing on a clean one. Pin a clean main-worktree fixture (an empty
# .env; get-config-var uses the load-env.js beside itself) as the inherited
# default: any row that does not set its own cap now resolves to the 5000 built-in. The G-series
# overrides AGENTS_MAIN_ROOT per row via PP_ENV, so this default never reaches it. The bare unset
# closes the same leak for the raw subshell rows, which do not strip the ambient key the way
# pp_run's `env -u` does.
unset CODEX_REVIEW_MAX_DIFF_LINES
CLEAN_CFG="$TMPDIR_BASE/clean-cfg"
mkdir -p "$CLEAN_CFG"
: > "$CLEAN_CFG/.env"
export AGENTS_MAIN_ROOT="$CLEAN_CFG"
# shellcheck source=../../lib/script-checkout-fixture.sh
source "$AGENTS_ROOT/tests/lib/script-checkout-fixture.sh"

# Built once (hooks disabled, one initial commit); each repo below is a copy of it.
# shellcheck source=../../lib/fixture-template.sh
. "$AGENTS_ROOT/tests/lib/fixture-template.sh"
REPO_TEMPLATE="$TMPDIR_BASE/repo-template"
fixture_template_git_repo "$REPO_TEMPLATE"

REPO="$TMPDIR_BASE/repo"
fixture_template_copy "$REPO_TEMPLATE" "$REPO"
git -C "$REPO" checkout -q -b feature-test
echo "change" >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "feature commit"

# Mock codex bin dir
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"

# Portable: use system timeout if available
_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 70 "$@"
    else
        perl -e 'alarm 70; exec @ARGV' -- "$@"
    fi
}

# Run script in $REPO with a given PATH and HOME
run_in_repo() {
    local _path="${1}"; shift
    local _home="$TMPDIR_BASE"
    (cd "$REPO" && PATH="$_path" HOME="$_home" _timeout bash "$SCRIPT" "$@") || true
}

# Status-preserving twin of run_in_repo, for rows asserting the exit-0 contract.
# run_in_repo's `|| true` masks the real exit status, so those rows need the actual code.
# Command substitution can't carry status either (subshell), so stdout/stderr go to a
# file and the real subprocess status is captured in RUN_STATUS for the caller.
RUN_STATUS=0
RUN_OUTPUT_FILE="$TMPDIR_BASE/run-output.txt"
run_in_repo_status() { # <path> [args...] ; sets RUN_STATUS and OUTPUT
    local _path="${1}"; shift
    RUN_STATUS=0
    (cd "$REPO" && PATH="$_path" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" "$@") \
        >"$RUN_OUTPUT_FILE" 2>&1 || RUN_STATUS=$?
    OUTPUT="$(cat "$RUN_OUTPUT_FILE")"
}

# Prints the summary and exits with the failure count.
rcc_finish() {
    echo ""
    if [[ $ERRORS -eq 0 ]]; then
        echo "All tests passed."
        exit 0
    else
        echo "$ERRORS test(s) failed."
        exit 1
    fi
}
