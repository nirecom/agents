#!/usr/bin/env bash
# Tests: bin/request-off-clearance
# Tags: scope:common, session-id
# Shared REAL-SUBPROCESS runner for bin/request-off-clearance (CPR-SSOT):
# fixture isolation (rules/test/fixture-isolation.md), SEPARATE stdout/stderr
# capture, a codex-free PATH, and single-var session-id source control.
# Sourced by the three tests/fix-1780-round12-*.sh suites.

OFFCLR_AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    OFFCLR_AGENTS_NODE="$(cygpath -m "$OFFCLR_AGENTS_DIR")"
else
    OFFCLR_AGENTS_NODE="$OFFCLR_AGENTS_DIR"
fi
OFFCLR_REQ="$OFFCLR_AGENTS_DIR/bin/request-off-clearance"
OFFCLR_RWT="$OFFCLR_AGENTS_DIR/bin/run-with-timeout.sh"
# shellcheck source=./examiner-stub.sh
. "$OFFCLR_AGENTS_DIR/tests/lib/examiner-stub.sh"

# ---- counters + reporting (identical style to the sibling fix-1780-round* files)
PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'offclr12'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
# `*.off-clearance` does NOT glob-match `*.off-clearance.claimed` — bare and
# claimed are counted separately on purpose.
token_count() { ls "$1"/*.off-clearance 2>/dev/null | wc -l | tr -d ' '; }
claim_count() { ls "$1"/*.off-clearance.claimed 2>/dev/null | wc -l | tr -d ' '; }
tmpres_count() { ls "$1"/*.mint.tmp "$1"/*.consuming-*.tmp 2>/dev/null | wc -l | tr -d ' '; }
state_has() { grep -rq "$2" "$1"/*-supervisor-state.json 2>/dev/null; }

# offclr_json <file> <js-expr over `t`> — read one field out of a JSON file.
offclr_json() {
    "$OFFCLR_RWT" 15 node -e '
const fs = require("fs");
let t;
try { t = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
catch (e) { process.stdout.write("UNREADABLE"); process.exit(0); }
let v;
try { v = eval(process.argv[2]); } catch (e) { v = "EVALFAIL"; }
process.stdout.write(v === undefined ? "(undef)" : String(v));
' "$1" "$2" 2>/dev/null
}

# ---- codex-free PATH -------------------------------------------------------
# `command -v codex` must genuinely FAIL, and the cheap tricks do not work here
# (a directory named `codex` still resolves; Git Bash calls every file
# executable, so a chmod-000 shadow is found too) — only removing the PATH
# entries that hold a real codex does. On this machine codex shares fnm's shim
# directory with `node`, which the script needs for the workflow dir, nonce,
# audit and mint, so the stripped PATH is re-supplied with a private shim that
# re-execs node by ABSOLUTE path: removing an entry must not smuggle in an
# unrelated failure mode (CPR-SC — the case is "codex is missing", nothing else).
OFFCLR_REAL_NODE="$(command -v node 2>/dev/null || true)"
offclr_strip_codex_dirs() {
    local cur="$PATH" hit d out rest p round=0
    while [ "$round" -lt 8 ]; do
        hit="$(PATH="$cur" command -v codex 2>/dev/null || true)"
        [ -n "$hit" ] || break
        d="$(dirname "$hit")"
        out=""; rest="$cur"
        while [ -n "$rest" ]; do
            case "$rest" in
                *:*) p="${rest%%:*}"; rest="${rest#*:}" ;;
                *)   p="$rest"; rest="" ;;
            esac
            [ "$p" = "$d" ] && continue
            out="${out:+$out:}$p"
        done
        cur="$out"
        round=$((round + 1))
    done
    printf '%s' "$cur"
}
OFFCLR_SHIM_DIR="$(make_tmp)"
if [ -n "$OFFCLR_REAL_NODE" ]; then
    printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(printf '%q' "$OFFCLR_REAL_NODE")" > "$OFFCLR_SHIM_DIR/node"
    chmod +x "$OFFCLR_SHIM_DIR/node"
fi
OFFCLR_CLEAN_PATH="$(offclr_strip_codex_dirs):$OFFCLR_SHIM_DIR"
trap 'rm -r -f "$OFFCLR_SHIM_DIR" 2>/dev/null || true' EXIT

# ---- the runner ------------------------------------------------------------
# Per-call knobs, reset by run_req after every call so a case never leaks into
# the next. REQ_SID is the value for CLAUDE_CODE_SESSION_ID — after #2270 the
# id reaches the tool only through bin/resolve-session-id's canonical variable
# — and empty means the var is left UNSET. REQ_ENV adds raw `env` arguments;
# REQ_CWD sets the working directory; REQ_NO_CONFIG_DIR=1 omits
# AGENTS_CONFIG_DIR entirely and REQ_CONFIG_DIR overrides its value (this is
# the seam a shadow config dir uses); REQ_NO_EXAMINER=1 installs no codex stub;
# REQ_TIMEOUT is the outer run-with-timeout budget.
# run_req <tmp_node> <stub-body> <args...> -> sets RC, OUT (stdout), ERR (stderr)
REQ_SID=""; REQ_ENV=(); REQ_CWD=""; REQ_NO_CONFIG_DIR=0; REQ_CONFIG_DIR=""; REQ_NO_EXAMINER=0; REQ_TIMEOUT=60
run_req() {
    local tn="$1" body="$2"; shift 2
    local stubbin outf errf cwd
    local -a envargs

    stubbin=$(make_tmp)
    if [ "$REQ_NO_EXAMINER" != "1" ]; then
        printf '%s' "$body" > "$stubbin/codex"
        chmod +x "$stubbin/codex"
    fi
    outf="$stubbin/.stdout"; errf="$stubbin/.stderr"
    cwd="${REQ_CWD:-$stubbin}"

    # Every inherited session-id spelling is dropped first; the case then opts
    # back in to exactly the ones it is testing.
    # AGENTS_CONFIG_DIR is unset first as well: it is exported by the developer's
    # live session, so "do not pass it" is not the same as "it is not there".
    envargs=(-u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u WORKTREE_PATH
             -u AGENTS_CONFIG_DIR
             "PATH=$stubbin:$OFFCLR_CLEAN_PATH"
             "WORKFLOW_PLANS_DIR=$tn" "CLAUDE_WORKFLOW_DIR=$tn")
    [ "$REQ_NO_CONFIG_DIR" = "1" ] || envargs+=("AGENTS_CONFIG_DIR=${REQ_CONFIG_DIR:-$OFFCLR_AGENTS_NODE}")
    [ -z "$REQ_SID" ] || envargs+=("CLAUDE_CODE_SESSION_ID=$REQ_SID")
    [ "${#REQ_ENV[@]}" -eq 0 ] || envargs+=("${REQ_ENV[@]}")

    ( cd "$cwd" && env "${envargs[@]}" "$OFFCLR_RWT" "$REQ_TIMEOUT" bash "$OFFCLR_REQ" "$@" ) \
        >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf" 2>/dev/null)"
    ERR="$(cat "$errf" 2>/dev/null)"

    rm -r -f "$stubbin" 2>/dev/null || true
    REQ_SID=""; REQ_ENV=(); REQ_CWD=""; REQ_NO_CONFIG_DIR=0; REQ_CONFIG_DIR=""; REQ_NO_EXAMINER=0; REQ_TIMEOUT=60
}

# allow_stub / reject_stub — the two everyday authentic examiners.
allow_stub() { examiner_stub_body "$(examiner_verdict_line ALLOW "${1:-legitimate workflow bug}" '$_n')"; }
reject_stub() { examiner_stub_body "$(examiner_verdict_line REJECT "${1:-use the sanctioned path}" '$_n')"; }

# offclr_require_script — H0 guard: without the binary every case is vacuous.
offclr_require_script() {
    if [ -f "$OFFCLR_REQ" ]; then
        pass "H0 bin/request-off-clearance present (harness self-check)"
        return 0
    fi
    fail "H0 bin/request-off-clearance MISSING at $OFFCLR_REQ - every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
}

offclr_report() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}
