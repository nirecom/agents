#!/bin/bash
# tests/feature-issue-528-lang-enforce.sh
# Tests: bin/compose-doc-append-entry, hooks/check-ask-lang.js, hooks/check-plan-lang.js, hooks/check-worktree-notes-lang.js, hooks/lib, hooks/lib/, hooks/lib/detect-cjk, hooks/lib/detect-cjk.js, hooks/lib/lang-config, hooks/lib/lang-config.js, hooks/lib/lint-plan-lang, hooks/lib/lint-plan-lang.js, hooks/lib/lint-worktree-notes-lang.js
# Tags: worktree, docs, append, history, compose, scope:issue-specific
# WORKTREE_NOTES.md language enforcement (#528), .env-only config (#619),
# DOCS_LANG_PUBLIC / DOCS_LANG_PRIVATE 2-key config with a legacy-key warning.
# Dispatcher: fixtures + helpers, then sources the per-group case files in
# feature-issue-528-lang-enforce/ (G1' loader, G2 lint lib, G3 hook, G4 compose,
# G5/G6 static + detect-cjk, G8 routing, G9-G12 plan lang + hint tier).
# lang-check: ignore -- this suite intentionally contains CJK test fixtures for CJK-detection tests
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CONFIG_LIB="$AGENTS_DIR/hooks/lib/lang-config.js"
LINT_LIB="$AGENTS_DIR/hooks/lib/lint-worktree-notes-lang.js"
HOOK="$AGENTS_DIR/hooks/check-worktree-notes-lang.js"
CLI="$AGENTS_DIR/bin/compose-doc-append-entry"
SETTINGS_JSON="$AGENTS_DIR/settings.json"

if command -v cygpath >/dev/null 2>&1; then
    CONFIG_LIB_NODE="$(cygpath -m "$CONFIG_LIB")"
    LINT_LIB_NODE="$(cygpath -m "$LINT_LIB")"
else
    CONFIG_LIB_NODE="$CONFIG_LIB"
    LINT_LIB_NODE="$LINT_LIB"
fi

PASS=0
FAIL=0
TEST_TMPS=()

cleanup_tmps() {
    for d in "${TEST_TMPS[@]}"; do
        [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup_tmps EXIT

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

# Echo "ok" or "missing" for a source file (helps mark RED-phase skips).
src_present() {
    if [ -f "$1" ]; then echo "ok"; else echo "missing"; fi
}

# Write a .env file in a fresh temp AGENTS_CONFIG_DIR and load the docs-lang
# config via the zero-arg loadDocsLangConfig() (post-#619 .env-only API).
# Args: $1=.env body (as written verbatim; may be empty for default)
#       $2 (optional)="no_env" to omit creating .env at all (missing-file case)
# Prints config JSON to stdout.
load_config_json_env() {
    local env_body="$1" mode="${2:-write}"
    local _iso; _iso=$(mktemp -d); TEST_TMPS+=("$_iso")
    if [ "$mode" != "no_env" ]; then
        printf '%s' "$env_body" > "$_iso/.env"
    fi
    local _iso_node; _iso_node="$(cygpath -m "$_iso" 2>/dev/null || echo "$_iso")"
    run_with_timeout 15 env \
        -u DOCS_LANG_PUBLIC -u DOCS_LANG_PRIVATE \
        -u DOCS_LANG_HISTORY_PUBLIC -u DOCS_LANG_HISTORY_PRIVATE \
        -u DOCS_LANG_CHANGELOG_PUBLIC -u DOCS_LANG_CHANGELOG_PRIVATE \
        AGENTS_CONFIG_DIR="$_iso_node" \
        node -e "
        const m = require('$CONFIG_LIB_NODE');
        const cfg = m.loadDocsLangConfig();
        process.stdout.write(JSON.stringify(cfg));
    " 2>/dev/null
}

# Shared runner behind load_config_stderr_env / load_config_json_ext.
# The 6 unsets (new 2 + legacy 4) are deliberately wider than production code:
# a test must never read a value the developer's shell happens to export, so the
# fixture .env is the only input the loader can see.
# Args: $1=stream ("err" -> stderr text, else config JSON on stdout)
#       $2=.env body ("__NO_ENV__" omits the file entirely)
#       $3=how many times to call loadDocsLangConfig() in the ONE process
#       $4.. = extra KEY=VALUE pairs placed after the -u list, so they DO reach
#              the child environment (T_new_9 puts a legacy key there).
run_config_load() {
    local stream="$1" env_body="$2" calls="$3"
    shift 3
    local _iso; _iso=$(mktemp -d); TEST_TMPS+=("$_iso")
    if [ "$env_body" != "__NO_ENV__" ]; then
        printf '%s' "$env_body" > "$_iso/.env"
    fi
    local _iso_node; _iso_node="$(cygpath -m "$_iso" 2>/dev/null || echo "$_iso")"
    local _script="
        const m = require('$CONFIG_LIB_NODE');
        let cfg = null;
        for (let i = 0; i < $calls; i++) { cfg = m.loadDocsLangConfig(); }
        process.stdout.write(JSON.stringify(cfg));
    "
    if [ "$stream" = "err" ]; then
        run_with_timeout 15 env \
            -u DOCS_LANG_PUBLIC -u DOCS_LANG_PRIVATE \
            -u DOCS_LANG_HISTORY_PUBLIC -u DOCS_LANG_HISTORY_PRIVATE \
            -u DOCS_LANG_CHANGELOG_PUBLIC -u DOCS_LANG_CHANGELOG_PRIVATE \
            AGENTS_CONFIG_DIR="$_iso_node" "$@" \
            node -e "$_script" 2>&1 >/dev/null
    else
        run_with_timeout 15 env \
            -u DOCS_LANG_PUBLIC -u DOCS_LANG_PRIVATE \
            -u DOCS_LANG_HISTORY_PUBLIC -u DOCS_LANG_HISTORY_PRIVATE \
            -u DOCS_LANG_CHANGELOG_PUBLIC -u DOCS_LANG_CHANGELOG_PRIVATE \
            AGENTS_CONFIG_DIR="$_iso_node" "$@" \
            node -e "$_script" 2>/dev/null
    fi
}

# stderr-capturing variant of load_config_json_env (2>/dev/null becomes
# 2>&1 >/dev/null). Args: $1=.env body, $2=call count (default 1), $3..=extra env.
load_config_stderr_env() {
    local body="$1"; shift
    local calls=1
    if [ $# -gt 0 ]; then calls="$1"; shift; fi
    run_config_load err "$body" "$calls" "$@"
}

# Config JSON with extra child-environment entries. Args: $1=.env body, $2..=extra env.
load_config_json_ext() {
    local body="$1"; shift
    run_config_load out "$body" 1 "$@"
}

# Run lint via node; print number of violations on stdout.
# Args: $1=content_file, $2=config_json, $3=options_json
lint_count() {
    local content_file="$1" cfg_json="$2" opts_json="$3"
    if command -v cygpath >/dev/null 2>&1; then
        content_file="$(cygpath -m "$content_file")"
    fi
    run_with_timeout 15 node -e "
        const fs = require('fs');
        const m = require('$LINT_LIB_NODE');
        const content = fs.readFileSync('$content_file', 'utf8');
        const cfg = $cfg_json;
        const opts = $opts_json;
        const v = m.lintWorktreeNotesLang(content, cfg, opts);
        process.stdout.write(String(Array.isArray(v) ? v.length : 0));
    " 2>/dev/null
}

# Run lint; print full violations JSON.
lint_json() {
    local content_file="$1" cfg_json="$2" opts_json="$3"
    if command -v cygpath >/dev/null 2>&1; then
        content_file="$(cygpath -m "$content_file")"
    fi
    run_with_timeout 15 node -e "
        const fs = require('fs');
        const m = require('$LINT_LIB_NODE');
        const content = fs.readFileSync('$content_file', 'utf8');
        const cfg = $cfg_json;
        const opts = $opts_json;
        const v = m.lintWorktreeNotesLang(content, cfg, opts);
        process.stdout.write(JSON.stringify(v));
    " 2>/dev/null
}

# Run the hook with a JSON input; print stdout.
# Args: $1=json, $2=optional AGENTS_CONFIG_DIR override
run_hook() {
    local json="$1" agents_dir="${2:-$AGENTS_CONFIG_DIR}"
    # Prevent shell DOCS_LANG_* leakage (#619 .env-only). Use a subshell with
    # unset so run_with_timeout (a bash function) remains in scope.
    (
        unset DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE
        unset DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE
        unset DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE
        export AGENTS_CONFIG_DIR="$agents_dir"
        echo "$json" | run_with_timeout 15 node "$HOOK" 2>/dev/null
    )
}

# Write a file and return its path; ensures parent dir.
write_tmp_file() {
    local tmp; tmp=$(mktemp -d)
    TEST_TMPS+=("$tmp")
    local f="$tmp/$1"
    mkdir -p "$(dirname "$f")"
    cat > "$f"
    echo "$f"
}

CASE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-issue-528-lang-enforce"

# shellcheck source=./feature-issue-528-lang-enforce/docs-lang-config-cases.sh
. "$CASE_DIR/docs-lang-config-cases.sh"
# shellcheck source=./feature-issue-528-lang-enforce/lint-worktree-notes-cases.sh
. "$CASE_DIR/lint-worktree-notes-cases.sh"
# shellcheck source=./feature-issue-528-lang-enforce/worktree-notes-hook-cases.sh
. "$CASE_DIR/worktree-notes-hook-cases.sh"
# shellcheck source=./feature-issue-528-lang-enforce/compose-doc-append-cases.sh
. "$CASE_DIR/compose-doc-append-cases.sh"
# Defines LANG_CONFIG_LIB (G7's leftover), which the next file and the hint-tier
# file both read — so it is sourced before them.
# shellcheck source=./feature-issue-528-lang-enforce/settings-and-detect-cjk-cases.sh
. "$CASE_DIR/settings-and-detect-cjk-cases.sh"
# shellcheck source=./feature-issue-528-lang-enforce/lang-config-routing-cases.sh
. "$CASE_DIR/lang-config-routing-cases.sh"
# shellcheck source=./feature-issue-528-lang-enforce/lint-plan-lang-cases.sh
. "$CASE_DIR/lint-plan-lang-cases.sh"
# Defines CHECK_PLAN_HOOK, reused by the hint-tier cases below.
# shellcheck source=./feature-issue-528-lang-enforce/check-plan-lang-hook-cases.sh
. "$CASE_DIR/check-plan-lang-hook-cases.sh"
# Sourced last: needs LANG_CONFIG_LIB and CHECK_PLAN_HOOK from the two above.
# shellcheck source=./feature-issue-528-lang-enforce/hint-tier-cases.sh
. "$CASE_DIR/hint-tier-cases.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
