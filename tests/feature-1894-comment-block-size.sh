#!/usr/bin/env bash
# tests/feature-1894-comment-block-size.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, parser, review-cli, staged, git, scope:issue-specific, scope:feature-1894, layer:TL2

# Issue #1894 scanner flags over-threshold comment runs (PR #1893 landed one
# unnoticed). Comparator is `>T`, not `>=T` — exactly T stays silent. `--staged`
# prints `BLOCK:`/exits 1; `--all` prints `WARN:`/exits 0 — use $CB_FIND /
# cb_expect_rc, never hardcode a prefix. Threshold/extensions/kill-switch
# resolve from the config dir's .env only, never ambient shell
# (config-hostility.sh: run_cb_ambient). Dispatcher: harness here, cases in
# tests/feature-1894-comment-block-size/*.sh, all via CLI stdout.

# TL3 gap: hook integration, installer PATH, pack-file sizes, NTFS-illegal
# names, symlinks, scanner footprint — see WORKFLOW_USER_VERIFIED preflight
# (bin/check-verification-gate.sh, category hook-registration).

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
# and the extension list. Every invocation starts from "all of them removed from
# the child environment" — including the two obsolete COMMENT_BLOCK_WARN* names,
# which must not be readable by any path — and then re-pins only what the case is
# about, through the fixture .env. Neither the ambient shell nor the developer's
# real config dir can decide an outcome (test-design.md "Config-dependent
# branches"). The file-count and byte-size caps are compiled-in constants with no
# knob at all — config-numeric-caps.sh pins both their boundaries and their
# non-configurability.
CB_ENV_RESET=(
    -u COMMENT_BLOCK_ENFORCE
    -u COMMENT_BLOCK_MAX_LINES
    -u CODE_FILE_EXTENSIONS
    -u COMMENT_BLOCK_WARN
    -u COMMENT_BLOCK_WARN_LINES
)
BASE_ENV=(
    "COMMENT_BLOCK_MAX_LINES=10"
    "CODE_FILE_EXTENSIONS=js;sh;py"
)
# The keys the CLI resolves from .env only. A VAR=VAL handed to run_cb whose key
# is in this list lands in the fixture .env; anything else (TMPDIR, the inert
# COMMENT_BLOCK_MAX_* knobs, ...) is passed as a genuine child environment
# variable, because that is what those cases are about.
CB_DOTENV_KEYS=" COMMENT_BLOCK_MAX_LINES COMMENT_BLOCK_ENFORCE CODE_FILE_EXTENSIONS COMMENT_BLOCK_WARN COMMENT_BLOCK_WARN_LINES "
# The fixture config dir. Without it the CLI's .env resolution would fall back to
# the installed agents repo and read the DEVELOPER's real .env.
CB_CFG_DIR="$TMPDIR_BASE/agents-config"
mkdir -p "$CB_CFG_DIR"
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

# _cb_invoke <repo> <use-base:0|1> <ambient-config:0|1> [VAR=VAL ...] -- [args]
# The one place that spawns the CLI. Splits the caller's VAR=VAL list on
# CB_DOTENV_KEYS: config keys go to $CB_CFG_DIR/.env (the only place the CLI
# may read them from); everything else is a real child env var. use-base=1
# also seeds the .env with BASE_ENV first (caller wins). ambient-config=1
# ALSO exports the config keys into the child env, with .env left holding the
# honest value — the hostile direction, proving the ambient copy is ignored.
# Sets CB_OUT / CB_ERR / CB_RC, and CB_MODE / CB_FIND from the CLI mode.
CB_OUT=""
CB_ERR=""
CB_RC=0
CB_MODE="none"
CB_FIND="WARN"
_cb_invoke() {
    local repo="$1" usebase="$2" ambient="$3"; shift 3
    local -a envs=("${CB_ENV_RESET[@]}")
    local -a kvs=()
    local kv key
    if [ "$usebase" = "1" ]; then kvs+=("${BASE_ENV[@]}"); fi
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do kvs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift

    # Later assignments win, so the .env is rebuilt from a last-wins pass rather
    # than appended to: a duplicated key would leave the winner up to the CLI's
    # own parser, which is not what any of these cases is about.
    local -a dot_keys=() dot_vals=()
    local i found
    for kv in ${kvs[@]+"${kvs[@]}"}; do
        key="${kv%%=*}"
        if [ "${CB_DOTENV_KEYS#* "$key" }" != "$CB_DOTENV_KEYS" ]; then
            found=-1
            for ((i = 0; i < ${#dot_keys[@]}; i++)); do
                [ "${dot_keys[$i]}" = "$key" ] && found=$i
            done
            if [ "$found" -ge 0 ]; then
                dot_vals[$found]="${kv#*=}"
            else
                dot_keys+=("$key"); dot_vals+=("${kv#*=}")
            fi
            [ "$ambient" = "1" ] && envs+=("$kv")
        else
            envs+=("$kv")
        fi
    done
    : > "$CB_CFG_DIR/.env"
    for ((i = 0; i < ${#dot_keys[@]}; i++)); do
        printf '%s=%s\n' "${dot_keys[$i]}" "${dot_vals[$i]}" >> "$CB_CFG_DIR/.env"
    done
    envs+=("AGENTS_CONFIG_DIR=$CB_CFG_DIR")

    CB_MODE="none"
    for kv in "$@"; do
        case "$kv" in
            --staged) CB_MODE="staged" ;;
            --all) CB_MODE="all" ;;
        esac
    done
    if [ "$CB_MODE" = "staged" ]; then CB_FIND="BLOCK"; else CB_FIND="WARN"; fi

    local errfile="$TMPDIR_BASE/cb.err"
    CB_RC=0
    CB_OUT="$( (cd "$repo" && run_with_timeout 60 env "${envs[@]}" bash "$SCRIPT" "$@") 2>"$errfile" )" || CB_RC=$?
    CB_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# run_cb <repo> [VAR=VAL ...] -- [cli args ...] — the default: config through
# the fixture .env, and genuinely absent from the child environment.
run_cb() { local r="$1"; shift; _cb_invoke "$r" 1 0 "$@"; }

# raw_cb — same, WITHOUT the BASE_ENV seed, so every config key the caller does
# not name is genuinely absent from the .env too (the built-in-default branches).
raw_cb() { local r="$1"; shift; _cb_invoke "$r" 0 0 "$@"; }

# run_cb_ambient — the hostile direction: the named config keys are exported
# into the child environment AS WELL AS written to the .env. Any behaviour
# difference against run_cb means an ambient value reached a verdict.
run_cb_ambient() { local r="$1"; shift; _cb_invoke "$r" 1 1 "$@"; }

cb_header() { printf '%s\n' "$CB_OUT" | head -1; }

# assert_finding / assert_no_finding — a finding line, without hardcoding the
# per-mode prefix. $CB_FIND is BLOCK after a --staged run and WARN after --all.
assert_finding() { assert_contains "$1" "$CB_FIND: $2" "$3"; }
assert_no_finding() { assert_absent "$1" "$CB_FIND: $2" "$3"; }

# cb_expect_rc <name> — the rc contract, which is mode-dependent:
#   --staged with at least one finding -> 1 (the commit-blocking verdict)
#   everything else                    -> 0
# Cases whose whole subject IS the rc (output-contract.sh O8, staged-regression
# R0) assert the literal instead; this helper exists so the ~40 incidental
# "and rc was still fine" assertions do not each have to restate the rule.
cb_expect_rc() {
    local name="$1" want=0
    if [ "$CB_MODE" = "staged" ] && [ "$(cb_finding_count)" -gt 0 ]; then want=1; fi
    assert_eq "$name" "$want" "$CB_RC"
}

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

# The number of finding lines, whichever prefix the mode uses. Counting both
# keeps a mis-prefixed report from passing as "no findings" — a report that
# printed WARN: in staged mode would otherwise silently satisfy every
# "exactly N findings" assertion in this suite while no longer blocking.
cb_finding_count() { printf '%s\n' "$CB_OUT" | grep -cE '^(WARN|BLOCK): ' || true; }
# Historical name kept for the case files; same meaning.
cb_warn_count() { cb_finding_count; }

# ============================================================================
# Cases
# ============================================================================
# shellcheck source=./feature-1894-comment-block-size/scanner-core.sh
. "$CASE_DIR/scanner-core.sh"
# shellcheck source=./feature-1894-comment-block-size/scan-core-node.sh
. "$CASE_DIR/scan-core-node.sh"
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
