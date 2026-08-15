#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block.sh
# Tests: hooks/block-comment-block-size.js, hooks/lib/comment-block-scan.js, settings.json
# Tags: comment-block-size, hook, pretooluse, edit-time, shift-left, no-bypass, dotenv, scope:issue-specific, scope:feature-1894, layer:TL2

# Issue #1894 — Edit-time half of the block, the half the issue was actually
# filed for. Pre-commit already caught these blocks but ~40% of sessions
# ignored it, so the user ended up pointing it out by hand; the cheapest fix
# point is the moment the block is written, not after it's staged. This hook
# is the shift-left; hooks/pre-commit is its backstop.

# The two layers deliberately judge differently (detail plan S3-2, CPR-SC):
# Edit-time (here) is PURE ABSOLUTE on the post-Edit file — blocked even if
# this edit didn't touch the violation and nothing got worse. pre-commit is
# baseline-relative — only a WORSENING blocks. The absolute rule is the sharp
# edge: a file with an old violation is unwritable until fixed (accepted,
# detail plan Risks #10) — pinned as a REQUIREMENT so a later "usability fix"
# reverting to worsening-only judgment fails a named test.

# Two ABSENCE properties get their own cases: no bypass — WORKFLOW_OFF /
# WORKTREE_OFF never suspend this hook because it never reads marker state
# (no-bypass.sh); config comes from the config dir's .env, never
# process.env, so an inline COMMENT_BLOCK_MAX_LINES can't lift the bar
# (filter-and-config.sh). Dispatcher: harness here, cases in
# tests/feature-1894-hook-comment-block/*.sh.

# TL3 gap: whether Claude Code actually routes a real Edit through this hook
# (cases feed a hand-built payload; registration.sh checks settings.json
# only); real editFiles/NotebookEdit payload shapes; latency. Mitigation:
# WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh, category
# hook-registration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The worktree copies are the state under test — never the deployed ~/.claude.
HOOK="$AGENTS_DIR/hooks/block-comment-block-size.js"
SCAN_MODULE="$AGENTS_DIR/hooks/lib/comment-block-scan.js"
SETTINGS_JSON="$AGENTS_DIR/settings.json"
SCANNER_SH="$AGENTS_DIR/bin/review-comment-block-size.d/scan.sh"
SCANNER_CLI="$AGENTS_DIR/bin/review-comment-block-size"
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1894-hook-comment-block"

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

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node runtime unavailable — the Edit-time hook cannot be exercised"
    exit 77
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin both dirs and
# drop any inherited session id, so a hook that DOES touch session state (the
# thing no-bypass.sh forbids) cannot reach the developer's real session.
CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export CLAUDE_WORKFLOW_DIR WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# Node on Windows wants a drive-letter path; msys hands us /c/... shapes.
mpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# The hook must never resolve paths against its own process.cwd(). Every
# invocation runs from here — a directory that is deliberately NOT the fixture
# repo and NOT a git repo — so a hook that falls back to process.cwd() reads the
# wrong file (or no file) and cannot accidentally pass.
NEUTRAL_CWD="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_CWD"

# Payload builder. Hand-writing PreToolUse JSON in bash means quoting file
# bodies that contain quotes, backslashes and newlines; a builder removes a
# whole class of test-only bugs. Usage:
#   node payload.js <tool_name> <cwd|-> <file_path|-> [key=value ...]
# value forms: `@<path>` reads the file, `e<N>.<key>=` fills edits[N],
# `replace_all=true|false` becomes a boolean, `!<key>=` sets a TOP-LEVEL
# payload key rather than a tool_input key.
PAYLOAD_JS="$TMPDIR_BASE/payload.js"
cat > "$PAYLOAD_JS" <<'PAYLOAD'
const fs = require("fs");
const [, , tool, cwd, filePath, ...rest] = process.argv;
const payload = {};
if (tool !== "-") payload.tool_name = tool;
if (cwd !== "-") payload.cwd = cwd;
const ti = {};
const edits = [];
for (const raw of rest) {
  const i = raw.indexOf("=");
  if (i < 0) continue;
  let key = raw.slice(0, i);
  let val = raw.slice(i + 1);
  if (val.startsWith("@")) val = fs.readFileSync(val.slice(1), "utf8");
  if (key.startsWith("!")) { payload[key.slice(1)] = val; continue; }
  const m = key.match(/^e(\d+)\.(.+)$/);
  if (m) {
    const n = Number(m[1]);
    while (edits.length <= n) edits.push({});
    if (m[2] === "replace_all") edits[n][m[2]] = val === "true";
    else edits[n][m[2]] = val;
    continue;
  }
  if (key === "replace_all") { ti[key] = val === "true"; continue; }
  ti[key] = val;
}
if (filePath !== "-") ti.file_path = filePath;
if (edits.length) ti.edits = edits;
payload.tool_input = ti;
process.stdout.write(JSON.stringify(payload));
PAYLOAD

# mkpayload <tool> <cwd|-> <file_path|-> [key=value ...] -> $PAYLOAD_FILE
PAYLOAD_FILE="$TMPDIR_BASE/payload.json"
mkpayload() {
    node "$PAYLOAD_JS" "$@" > "$PAYLOAD_FILE"
}

# ---------------------------------------------------------------------------
# Config routing. The hook resolves COMMENT_BLOCK_* and CODE_FILE_EXTENSIONS
# from the config dir's .env ONLY. Tests therefore write .env and, by default,
# scrub those names from the child environment; hk_run_ambient exports them too,
# which is the spoof the .env-only rule exists to defeat.
# ---------------------------------------------------------------------------
HK_ENV_RESET=(
    -u COMMENT_BLOCK_ENFORCE
    -u COMMENT_BLOCK_MAX_LINES
    -u CODE_FILE_EXTENSIONS
    -u COMMENT_BLOCK_WARN
    -u COMMENT_BLOCK_WARN_LINES
    -u CLAUDE_PROJECT_DIR
)
HK_DOTENV_KEYS=" COMMENT_BLOCK_MAX_LINES COMMENT_BLOCK_ENFORCE CODE_FILE_EXTENSIONS COMMENT_BLOCK_WARN COMMENT_BLOCK_WARN_LINES "
HK_BASE_ENV=(
    "COMMENT_BLOCK_MAX_LINES=10"
    "CODE_FILE_EXTENSIONS=js;sh;py"
)

CFG_DIR="$TMPDIR_BASE/agents-config"
mkdir -p "$CFG_DIR"

HK_ENVS=()
# _hk_env <ambient:0|1> [VAR=VAL ...] — rewrites $CFG_DIR/.env and fills HK_ENVS.
_hk_env() {
    local ambient="$1"; shift
    HK_ENVS=("${HK_ENV_RESET[@]}")
    local -a kvs=("${HK_BASE_ENV[@]}") dot_keys=() dot_vals=()
    local kv key i found
    kvs+=("$@")
    for kv in ${kvs[@]+"${kvs[@]}"}; do
        key="${kv%%=*}"
        if [ "${HK_DOTENV_KEYS#* "$key" }" != "$HK_DOTENV_KEYS" ]; then
            found=-1
            for ((i = 0; i < ${#dot_keys[@]}; i++)); do
                [ "${dot_keys[$i]}" = "$key" ] && found=$i
            done
            if [ "$found" -ge 0 ]; then dot_vals[$found]="${kv#*=}"
            else dot_keys+=("$key"); dot_vals+=("${kv#*=}"); fi
            [ "$ambient" = "1" ] && HK_ENVS+=("$kv")
        else
            HK_ENVS+=("$kv")
        fi
    done
    : > "$CFG_DIR/.env"
    for ((i = 0; i < ${#dot_keys[@]}; i++)); do
        printf '%s=%s\n' "${dot_keys[$i]}" "${dot_vals[$i]}" >> "$CFG_DIR/.env"
    done
    HK_ENVS+=("AGENTS_CONFIG_DIR=$(mpath "$CFG_DIR")")
}

HK_OUT=""
HK_ERR=""
HK_RC=0
HK_DECISION="none"

# hk_run [VAR=VAL ...] — feeds $PAYLOAD_FILE to the hook. Config-owned names go
# to .env; anything else becomes a plain child variable.
hk_run() { _hk_run 0 "$@"; }
# Same, with the config names ALSO exported (hostile direction).
hk_run_ambient() { _hk_run 1 "$@"; }
_hk_run() {
    local ambient="$1"; shift
    _hk_env "$ambient" "$@"
    local errfile="$TMPDIR_BASE/hook.err"
    HK_RC=0
    HK_OUT="$( (cd "$NEUTRAL_CWD" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 30 env "${HK_ENVS[@]}" \
            node "$(mpath "$HOOK")" < "$PAYLOAD_FILE") 2>"$errfile" )" || HK_RC=$?
    HK_ERR="$(cat "$errfile" 2>/dev/null || true)"
    local squashed="${HK_OUT//[[:space:]]/}"
    case "$squashed" in
        *'"decision":"block"'*)   HK_DECISION="block" ;;
        *'"decision":"approve"'*) HK_DECISION="approve" ;;
        *)                        HK_DECISION="none" ;;
    esac
}

# assert_decision <name> <want> — with the raw output in the failure detail,
# because "none" on its own never says why.
assert_decision() {
    local name="$1" want="$2"
    if [ "$want" = "$HK_DECISION" ]; then pass "$name"
    else fail "$name" "want=$want got=$HK_DECISION rc=$HK_RC out=$HK_OUT err=$HK_ERR"; fi
}

# A hook that crashes must fail OPEN, and it must do so through an approve
# verdict rather than through a non-zero exit that Claude Code would surface as
# a hook error on every keystroke.
assert_clean_exit() {
    assert_eq "$1" "0" "$HK_RC"
}

# Side-effect / protection helpers (Codex round-1 C3). A PreToolUse hook
# advises the tool-use layer; it must never perform the write itself. The
# verdict assertions above can't distinguish a hook that judged a
# reconstructed buffer from one that judged the file after writing it — and
# writing on the Edit hot path is a data-loss bug, not a policy bug. So every
# verdict row also pins on-disk state: existing files stay byte-identical,
# absent files stay absent. snap_file <path> -> "absent" or
# "present:<cksum> <bytes>"; reads via stdin redirection so drive-letter
# (mpath) paths work on Windows bash too.
snap_file() {
    local p="$1"
    if [ -e "$p" ]; then
        printf 'present:%s' "$(cksum < "$p" 2>/dev/null || echo unreadable)"
    else
        printf 'absent'
    fi
}
# assert_file_untouched <name> <path> <snapshot-taken-before-hk_run>
assert_file_untouched() {
    local name="$1" p="$2" before="$3"
    local after; after="$(snap_file "$p")"
    if [ "$before" = "$after" ]; then
        pass "$name"
    else
        fail "$name" "the hook mutated $p — before=$before after=$after"
    fi
}
# assert_file_absent <name> <path> — for proposed new files that must not
# materialise merely because the hook looked at the payload.
assert_file_absent() {
    local name="$1" p="$2"
    if [ -e "$p" ]; then
        fail "$name" "the hook created $p"
    else
        pass "$name"
    fi
}

# ---------------------------------------------------------------------------
# Content helpers
# ---------------------------------------------------------------------------
# cmt <n> [tag] — n consecutive `//` comment lines.
cmt() {
    local n="$1" tag="${2:-note}" i
    for ((i = 1; i <= n; i++)); do echo "// $tag $i"; done
}
# cmtn <n> [tag] — same, with NO trailing newline. Replacement strings need
# this: an Edit whose old_string is a whole line ("MARK") is replaced by text
# that must not carry its own line terminator, or the result gains a blank line
# — and a blank line splits a comment run, which silently turns a 12-line
# expectation into two runs of 6.
cmtn() {
    local n="$1" tag="${2:-note}" i
    for ((i = 1; i <= n; i++)); do
        [ "$i" -gt 1 ] && printf '\n'
        printf '// %s %s' "$tag" "$i"
    done
}
# code <n> — n consecutive non-comment lines.
code() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "var v$i = $i;"; done
}

REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || true
cat >> "$REPO/.git/config" <<'CFG'
[user]
	email = test@example.com
	name = Test
[core]
	hooksPath = /dev/null
	autocrlf = false
CFG
REPO_M="$(mpath "$REPO")"

# wfile <relative-path> — writes stdin to $REPO/<path> and echoes the absolute
# path in the shape a hook payload would carry.
wfile() {
    local rel="$1"
    mkdir -p "$(dirname "$REPO/$rel")"
    cat > "$REPO/$rel"
    printf '%s' "$REPO_M/$rel"
}

if [ ! -f "$HOOK" ]; then
    echo "NOTE: $HOOK does not exist yet — every case below is expected to fail"
    echo "      until hooks/block-comment-block-size.js is implemented (issue #1894)."
fi

# ============================================================================
# Cases
# ============================================================================
# shellcheck source=feature-1894-hook-comment-block/decision-boundary.sh
. "$CASE_DIR/decision-boundary.sh"
# shellcheck source=feature-1894-hook-comment-block/payload-shapes.sh
. "$CASE_DIR/payload-shapes.sh"
# shellcheck source=feature-1894-hook-comment-block/path-resolution.sh
. "$CASE_DIR/path-resolution.sh"
# shellcheck source=feature-1894-hook-comment-block/filter-and-config.sh
. "$CASE_DIR/filter-and-config.sh"
# shellcheck source=feature-1894-hook-comment-block/no-bypass.sh
. "$CASE_DIR/no-bypass.sh"
# shellcheck source=feature-1894-hook-comment-block/registration.sh
. "$CASE_DIR/registration.sh"
# shellcheck source=feature-1894-hook-comment-block/filter-parity.sh
. "$CASE_DIR/filter-parity.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
