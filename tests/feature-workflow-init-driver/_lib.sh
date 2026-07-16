#!/bin/bash
# tests/feature-workflow-init-driver/_lib.sh — shared helper library, NOT a test file.
# Source from sibling tests: . "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#
# TDD red phase: the SUT (bin/workflow/workflow-init-driver) does not exist yet.
# Injection seams the driver implementation MUST honor (write-code contract):
#
# CONTRACT: `gh` is spawned via bare PATH lookup (never an absolute path) — the
#   harness intercepts it with a PATH-prepended mock; fixtures live in $RESP and
#   every invocation appends one line to $GH_LOG (call-count assertions C2/C6/C7).
# CONTRACT: wip-state.sh is resolved as $AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh
#   when AGENTS_CONFIG_DIR is set (repo-root-relative fallback only when unset).
#   The harness points AGENTS_CONFIG_DIR at a per-case mock config root.
# CONTRACT: the checkpoint JSON (<sid>-wi-checkpoint.json) and context.md are
#   written under the directory given by the WORKFLOW_PLANS_DIR env var when set.
# CONTRACT: CLAUDE_SESSION_ID env provides the session id deterministically; the
#   mock config root also ships bin/resolve-session-id echoing $CLAUDE_SESSION_ID
#   in case the driver unconditionally spawns that primitive.
# CONTRACT: NON_GITHUB=1 env activates the WI-2 non-GitHub gate.
# CONTRACT: positional CLI args are the raw issue tokens (`#N`, `repo#N`,
#   `owner/repo#N`) from the user's invocation; zero tokens = zero-issue pipeline
#   (Path C). intent.md does NOT exist at workflow-init time — never read it.
# CONTRACT: on checkpoint version mismatch the driver ignores the checkpoint and
#   restarts from the first phase, re-detecting issues from the positional tokens
#   supplied on that same invocation.
#
# WID_DRIVER_OVERRIDE is a harness-self-check seam only (runs the suite against a
# stand-in driver outside the repo); it is NOT part of the driver contract.

set -u

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$_LIB_DIR/../.." && pwd)"
DRIVER="${WID_DRIVER_OVERRIDE:-$AGENTS_DIR/bin/workflow/workflow-init-driver}"
TIMEOUT_WRAP="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# MSYS → POSIX (/tmp/...) so paths work both in bash PATH entries and in Node I/O.
# cygpath -u converts C:/... to /tmp/... which Node on Windows resolves correctly via
# MSYS2 path mapping, and which bash PATH splitting preserves (no drive-letter colon split).
to_native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

require_sut() {
    if [ ! -f "$DRIVER" ]; then
        echo "SUT missing: bin/workflow/workflow-init-driver not yet implemented (TDD red phase)"
        exit 1
    fi
}

ROOT_TMP="$(to_native "$(mktemp -d)")"
trap 'rm -rf "$ROOT_TMP"' EXIT
ORIG_PATH="$PATH"
_CASE_N=0

# --- per-case environment ---------------------------------------------------
setup_case() {  # <session-id>
    SID="$1"
    _CASE_N=$((_CASE_N + 1))
    CASE_DIR="$ROOT_TMP/case-$_CASE_N"
    PLANS="$CASE_DIR/plans"
    CFG="$CASE_DIR/agents-config"
    MOCKBIN="$CASE_DIR/mock-bin"
    RESP="$CASE_DIR/gh-responses"
    WIPD="$CASE_DIR/wip"
    GH_LOG="$CASE_DIR/gh-calls.log"
    mkdir -p "$PLANS" "$MOCKBIN" "$RESP" "$WIPD" \
        "$CFG/bin/github-issues" "$CFG/hooks/lib" "$CFG/skills/workflow-init/scripts"
    _write_gh_mock
    _write_wip_mock
    _write_cfg_prims
    export WORKFLOW_PLANS_DIR="$PLANS"
    export AGENTS_CONFIG_DIR="$CFG"
    export CLAUDE_SESSION_ID="$SID"
    unset NON_GITHUB CLAUDE_ENV_FILE 2>/dev/null || true
    export PATH="$MOCKBIN:$ORIG_PATH"
}

teardown_case() {
    export PATH="$ORIG_PATH"
    unset WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR CLAUDE_SESSION_ID NON_GITHUB 2>/dev/null || true
}

# --- mocks -------------------------------------------------------------------
_write_gh_mock() {
    cat > "$MOCKBIN/gh" <<MOCKGH1
#!/bin/bash
echo "\$*" >> "$GH_LOG"
RESP="$RESP"
MOCKGH1
    cat >> "$MOCKBIN/gh" <<'MOCKGH2'
cmd="${1:-}"; sub="${2:-}"
if [ "$cmd" = "issue" ] && [ "$sub" = "view" ]; then
    shift 2; N=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|--json|--jq) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) [ -z "$N" ] && N="$1"; shift ;;
        esac
    done
    N="${N#\#}"
    rc=0; [ -f "$RESP/issue-view-$N.rc" ] && rc="$(cat "$RESP/issue-view-$N.rc")"
    if [ "$rc" != "0" ]; then echo "mock-gh: forced failure for issue $N" >&2; exit "$rc"; fi
    if [ -f "$RESP/issue-view-$N.json" ]; then cat "$RESP/issue-view-$N.json"; exit 0; fi
    echo "mock-gh: no fixture for issue $N" >&2; exit 1
fi
if [ "$cmd" = "issue" ] && [ "$sub" = "reopen" ]; then exit 0; fi
if [ "$cmd" = "repo" ] && [ "$sub" = "view" ]; then
    if printf '%s' "$*" | grep -q -- "--jq"; then echo "mockorg/mockrepo"
    else echo '{"nameWithOwner":"mockorg/mockrepo"}'; fi
    exit 0
fi
if [ "$cmd" = "api" ]; then
    if [[ "${2:-}" =~ issues/([0-9]+)/sub_issues ]]; then
        M="${BASH_REMATCH[1]}"
        if [ -f "$RESP/sub-issues-$M.json" ]; then cat "$RESP/sub-issues-$M.json"; else echo "[]"; fi
        exit 0
    fi
    echo "{}"; exit 0
fi
echo "mock-gh: unhandled args: $*" >&2
exit 1
MOCKGH2
    chmod +x "$MOCKBIN/gh"
}

_write_wip_mock() {
    cat > "$CFG/bin/github-issues/wip-state.sh" <<MOCKWIP1
#!/bin/bash
WIPD="$WIPD"
MOCKWIP1
    cat >> "$CFG/bin/github-issues/wip-state.sh" <<'MOCKWIP2'
VERB=""; N=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id|--repo) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        -*) shift ;;
        *) if [ -z "$VERB" ]; then VERB="$1"; elif [ -z "$N" ]; then N="$1"; fi; shift ;;
    esac
done
N="${N#\#}"
echo "$VERB $N" >> "$WIPD/calls.log"
case "$VERB" in
    check)
        rc=0
        [ -f "$WIPD/check-rc" ] && rc="$(cat "$WIPD/check-rc")"
        [ -f "$WIPD/check-rc-$N" ] && rc="$(cat "$WIPD/check-rc-$N")"
        if [ "$rc" != "0" ]; then echo "wip-state mock: forced check error for #$N" >&2; exit "$rc"; fi
        if [ -f "$WIPD/state-$N" ]; then cat "$WIPD/state-$N"; else echo "none"; fi
        exit 0 ;;
    set)
        rc=0
        [ -f "$WIPD/set-rc" ] && rc="$(cat "$WIPD/set-rc")"
        [ -f "$WIPD/set-rc-$N" ] && rc="$(cat "$WIPD/set-rc-$N")"
        if [ "$rc" = "0" ]; then echo "same" > "$WIPD/state-$N"; fi
        exit "$rc" ;;
    clear|abandon) exit 0 ;;
esac
echo "wip-state mock: unhandled verb '$VERB'" >&2
exit 2
MOCKWIP2
    chmod +x "$CFG/bin/github-issues/wip-state.sh"
}

_write_cfg_prims() {
    printf '#!/bin/bash\necho "${CLAUDE_SESSION_ID:-mock-sid}"\n' > "$CFG/bin/resolve-session-id"
    cp "$AGENTS_DIR/bin/parse-issue-tokens" "$CFG/bin/parse-issue-tokens"
    cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$CFG/hooks/lib/parse-closes-issues.js"
    cat > "$CFG/skills/workflow-init/scripts/filter-init-candidates.sh" <<'FILT'
#!/bin/bash
# Passthrough filter mock: emit every issue-number arg back as '#N' (no filtering).
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-map) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        -*) shift ;;
        *) echo "#${1#\#}"; shift ;;
    esac
done
exit 0
FILT
    chmod +x "$CFG/bin/resolve-session-id" "$CFG/bin/parse-issue-tokens" \
        "$CFG/skills/workflow-init/scripts/filter-init-candidates.sh"
}

# --- fixtures ----------------------------------------------------------------
mock_issue() {  # <N> <STATE> [labels-csv] [title]
    local n="$1" state="$2" labels_csv="${3:-}" title="${4:-Issue $1}" labels="" l
    local IFS=','
    for l in $labels_csv; do labels="$labels{\"name\":\"$l\"},"; done
    labels="[${labels%,}]"
    printf '{"number":%s,"title":"%s","body":"Body of issue %s","labels":%s,"state":"%s","createdAt":"2026-07-01T00:00:00Z"}\n' \
        "$n" "$title" "$n" "$labels" "$state" > "$RESP/issue-view-$n.json"
}
mock_issue_rc() { echo "$2" > "$RESP/issue-view-$1.rc"; }        # <N> <rc>
mock_sub_issues() { printf '%s\n' "$2" > "$RESP/sub-issues-$1.json"; }  # <N> <json>
set_wip() { echo "$2" > "$WIPD/state-$1"; }                      # <N> same|none|other
set_wip_check_rc() { echo "$1" > "$WIPD/check-rc"; }             # <rc> (all N)
set_wip_set_rc() { echo "$1" > "$WIPD/set-rc"; }                 # <rc> (all N)

# --- SUT invocation ----------------------------------------------------------
run_driver() {  # [driver args...] — sets DRIVER_OUT / DRIVER_RC / DRIVER_ERR
    local errf="$CASE_DIR/driver-stderr.log"
    DRIVER_OUT="$(cd "$CASE_DIR" && "$TIMEOUT_WRAP" 30 node "$DRIVER" "$@" 2>"$errf")"
    DRIVER_RC=$?
    DRIVER_ERR=""
    [ -f "$errf" ] && DRIVER_ERR="$(cat "$errf")"
    return 0
}

# --- directive / checkpoint accessors -----------------------------------------
get_kv() {  # <KEY> — reads from $DRIVER_OUT; strips optional single-quote wrapping
    local key="$1" line val
    line="$(printf '%s\n' "$DRIVER_OUT" | grep -m1 "^${key}=")" || { printf ''; return 1; }
    val="${line#"${key}"=}"
    val="${val%$'\r'}"
    case "$val" in
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf '%s' "$val"
}

count_gh_calls() {  # <ERE> — count matching lines in the gh call log
    if [ -f "$GH_LOG" ]; then grep -Ec -- "$1" "$GH_LOG" || true; else echo 0; fi
}

wip_set_calls() {  # print 'set <N>' lines recorded by the wip-state mock
    if [ -f "$WIPD/calls.log" ]; then grep '^set ' "$WIPD/calls.log" || true; else printf ''; fi
}

ckpt_get() {  # <ckpt-path> <dot.path> — prints value; <missing>/<unreadable> on error
    if [ -z "$1" ] || [ ! -f "$1" ]; then printf '<unreadable>'; return 0; fi
    node -e '
const fs = require("fs");
let v;
try { v = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.stdout.write("<unreadable>"); process.exit(0); }
for (const k of process.argv[2].split(".")) { if (v == null) break; v = v[k]; }
if (v === undefined || v === null) process.stdout.write("<missing>");
else if (typeof v === "object") process.stdout.write(JSON.stringify(v));
else process.stdout.write(String(v));
' "$1" "$2" 2>/dev/null || printf '<unreadable>'
}

pct_decode() {  # <encoded> — prints decoded string; rc!=0 when malformed
    node -e 'try{process.stdout.write(decodeURIComponent(process.argv[1]))}catch(e){process.exit(3)}' "$1"
}

# --- assertions ----------------------------------------------------------------
assert_kv() {  # <label> <KEY> <want>
    local got
    got="$(get_kv "$2")" || true
    if [ "$got" = "$3" ]; then pass "$1"; else fail "$1: want $2=$3 got $2='$got' (rc=$DRIVER_RC)"; fi
}

assert_nonempty_kv() {  # <label> <KEY>
    local got
    got="$(get_kv "$2")" || true
    if [ -n "$got" ]; then pass "$1"; else fail "$1: $2= missing/empty (rc=$DRIVER_RC)"; fi
}

assert_single_action_line() {  # <label>
    local c
    c="$(printf '%s\n' "$DRIVER_OUT" | grep -c '^ACTION=')" || true
    if [ "$c" = "1" ]; then pass "$1"; else fail "$1: expected exactly 1 ACTION= line, got $c"; fi
}

assert_ckpt() {  # <label> <ckpt-path> <dot.path> <want>
    local got
    got="$(ckpt_get "$2" "$3")"
    if [ "$got" = "$4" ]; then pass "$1"; else fail "$1: want $3=$4 got '$got'"; fi
}

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}
