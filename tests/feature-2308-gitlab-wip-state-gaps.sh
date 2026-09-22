#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/gitlab.sh
# Tags: scope:issue-specific, gitlab, wip-state, forge, TL2
set -u

# Issue #2308 — GitLab WIP verb (gitlab.sh) gaps unreached by
# feature-2308-gitlab-wip-state.sh: Gap 1 = gl_cmd_check "wip-other" (status:wip
# present but stored wip-fp mismatches the checking session — the sibling reuses
# one SID so this branch never runs); Gap 2 = gl_cmd_abandon (open→remove labels;
# closed/unknown→exit 1) plus its `api .../issues/<N> --jq .state` read the
# sibling glab mock does not answer. glab/gh mocked as PATH scripts, no real API.
# # TL3 gap — real glab label/state calls vs live GitLab not exercised here.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET="$AGENTS_DIR/bin/github-issues/wip-state.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Isolated fixture config dir (no .env). Plans dir dual-pinned per
# rules/test/fixture-isolation.md; inherited session ids cleared.
FIX_CFG="$TMPROOT/config"
mkdir -p "$FIX_CFG"
export AGENTS_CONFIG_DIR="$FIX_CFG"
export WORKFLOW_PLANS_DIR="$TMPROOT/plans"
export CLAUDE_WORKFLOW_DIR="$TMPROOT/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
unset WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
      WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
      WIP_STATE_FINGERPRINT_FIELD_ID 2>/dev/null || true

SID_A="sid-2308-A"
SID_B="sid-2308-B"

# Mock bin: glab is a STATEFUL label store (logs argv, applies
# --label/--remove-label to a per-issue set, answers `--json labels` from it, and
# answers `api .../issues/<N> --jq .state` from GLAB_MOCK_ISSUE_STATE). gh logs
# argv and fails every call.
MOCK_BIN="$TMPROOT/mock-bin"
mkdir -p "$MOCK_BIN"
GLAB_LOG="$TMPROOT/glab.log"
GH_LOG="$TMPROOT/gh.log"
GLAB_STATE_DIR="$TMPROOT/glab-state"
mkdir -p "$GLAB_STATE_DIR"
export GLAB_MOCK_LOG="$GLAB_LOG"
export GH_MOCK_LOG="$GH_LOG"
export GLAB_STATE_DIR
export GLAB_MOCK_ISSUE_STATE="opened"

cat > "$MOCK_BIN/glab" <<'GLABEOF'
#!/bin/bash
# Stateful glab mock: --label/--remove-label mutate a per-issue label set,
# `--json labels` reads it back, `api .../issues/<N> --jq .state` answers from
# GLAB_MOCK_ISSUE_STATE.
printf '%s\n' "$*" >> "$GLAB_MOCK_LOG"

issue=""
add_tokens=""
del_tokens=""
prev=""
for a in "$@"; do
    case "$a" in
        --label=*|--labels=*)          add_tokens="$add_tokens ${a#*=}" ;;
        --unlabel=*|--remove-label=*)  del_tokens="$del_tokens ${a#*=}" ;;
        *)
            case "$prev" in
                --label|-l|--labels)          add_tokens="$add_tokens $a" ;;
                --unlabel|--remove-label)     del_tokens="$del_tokens $a" ;;
            esac
            ;;
    esac
    case "$a" in
        [0-9]*) [ -z "$issue" ] && [ -z "${a//[0-9]/}" ] && issue="$a" ;;
    esac
    prev="$a"
done

statefile=""
if [ -n "$issue" ] && [ -n "${GLAB_STATE_DIR:-}" ]; then
    statefile="$GLAB_STATE_DIR/labels-$issue"
    touch "$statefile"
fi

apply_label() { # $1 = state file, $2 = comma/space list, $3 = add|del
    local sf="$1" list="$2" mode="$3" tok
    [ -z "$sf" ] && return 0
    list="${list//,/ }"
    for tok in $list; do
        [ -z "$tok" ] && continue
        grep -v -x -- "$tok" "$sf" > "$sf.tmp" 2>/dev/null || true
        mv "$sf.tmp" "$sf" 2>/dev/null || true
        [ "$mode" = "add" ] && printf '%s\n' "$tok" >> "$sf"
    done
}
apply_label "$statefile" "$del_tokens" del
apply_label "$statefile" "$add_tokens" add

case "$*" in
    *api*issues*)
        echo "${GLAB_MOCK_ISSUE_STATE:-opened}"
        ;;
    *"--json labels"*|*"--json"*"labels"*)
        body="[]"
        if [ -n "$statefile" ] && [ -s "$statefile" ]; then
            body="["
            first=1
            while IFS= read -r ln; do
                [ -z "$ln" ] && continue
                [ "$first" -eq 1 ] || body="$body,"
                body="$body{\"name\":\"$ln\"}"
                first=0
            done < "$statefile"
            body="$body]"
        fi
        echo "$body"
        ;;
    *"--json"*) echo "[]" ;;
    *) echo "" ;;
esac
exit 0
GLABEOF
chmod +x "$MOCK_BIN/glab"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_MOCK_LOG"\nexit 1\n' > "$MOCK_BIN/gh"
chmod +x "$MOCK_BIN/gh"

reset_logs() { : > "$GLAB_LOG"; : > "$GH_LOG"; }
reset_state() { rm -f "$GLAB_STATE_DIR"/labels-* 2>/dev/null || true; }
seed_labels() { # $1 = issue N, $2.. = labels to pre-set
    local n="$1"; shift
    local sf="$GLAB_STATE_DIR/labels-$n"
    : > "$sf"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$sf"; done
}
state_has() { grep -q -x -- "$2" "$GLAB_STATE_DIR/labels-$1" 2>/dev/null; }

make_repo() {
    local url="$1"
    local repo="$TMPROOT/repo-$RANDOM$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote add origin "$url"
    printf '%s' "$repo"
}

LAST_RC=0
LAST_ERR=""
LAST_OUT=""
run_wip() {
    local repo="$1"; shift
    local errf="$TMPROOT/err-$RANDOM"
    local outf="$TMPROOT/out-$RANDOM"
    ( cd "$repo" && PATH="$MOCK_BIN:$PATH" run_with_timeout 60 bash "$TARGET" "$@" ) >"$outf" 2>"$errf"
    LAST_RC=$?
    LAST_ERR="$(cat "$errf" 2>/dev/null)"
    LAST_OUT="$(cat "$outf" 2>/dev/null)"
    rm -f "$errf" "$outf"
}

REPO_GL="$(make_repo 'git@gitlab.com:acme/widgets.git')"

echo "=== Gap 1: gl_cmd_check wip-other / wip-same fingerprint routing ==="

# G1-setup: set 42 with session A → status:wip + wip-fp:<hashA> applied.
reset_logs; reset_state
run_wip "$REPO_GL" set 42 --session-id "$SID_A"
if [ "$LAST_RC" -eq 0 ] && state_has 42 "status:wip"; then
    pass "G1-setup: set 42 (session A) → exit 0, status:wip applied"
else
    fail "G1-setup: expected exit 0 + status:wip (rc=$LAST_RC) state=[$(cat "$GLAB_STATE_DIR/labels-42" 2>/dev/null | tr '\n' ',')] err=[$LAST_ERR]"
fi

# G1a (primary): check 42 with a DIFFERENT session B → status:wip present but the
# stored fingerprint is session A's → mismatch → "wip-other".
reset_logs
run_wip "$REPO_GL" check 42 --session-id "$SID_B"
if [ "$LAST_RC" -eq 0 ] && [ "$LAST_OUT" = "wip-other" ]; then
    pass "G1a: check 42 (session B) → wip-other, exit 0"
else
    fail "G1a: expected 'wip-other' + exit 0 (rc=$LAST_RC) out=[$LAST_OUT] err=[$LAST_ERR]"
fi

# G1b (positive control): check 42 with the SAME session A → fingerprint matches
# → "wip-same". Proves the verdict is fingerprint-driven, not constant.
reset_logs
run_wip "$REPO_GL" check 42 --session-id "$SID_A"
if [ "$LAST_RC" -eq 0 ] && [ "$LAST_OUT" = "wip-same" ]; then
    pass "G1b: check 42 (session A) → wip-same, exit 0"
else
    fail "G1b: expected 'wip-same' + exit 0 (rc=$LAST_RC) out=[$LAST_OUT] err=[$LAST_ERR]"
fi

echo ""
echo "=== Gap 2: gl_cmd_abandon (open→remove labels; closed/unknown→exit 1) ==="

# G2a: opened issue with status:wip + wip-fp:* → abandon removes BOTH and exits 0.
# abandon does NOT accept --session-id, so it is omitted.
reset_logs; reset_state
seed_labels 50 "status:wip" "wip-fp:deadbeef"
export GLAB_MOCK_ISSUE_STATE="opened"
run_wip "$REPO_GL" abandon 50
if [ "$LAST_RC" -eq 0 ] \
   && ! state_has 50 "status:wip" && ! state_has 50 "wip-fp:deadbeef"; then
    pass "G2a: abandon opened #50 → exit 0, status:wip + wip-fp removed"
else
    fail "G2a: expected exit 0 + labels removed (rc=$LAST_RC) state=[$(cat "$GLAB_STATE_DIR/labels-50" 2>/dev/null | tr '\n' ',')] err=[$LAST_ERR]"
fi

# G2b: closed issue → abandon refuses (exit 1), labels untouched.
reset_logs; reset_state
seed_labels 51 "status:wip" "wip-fp:deadbeef"
export GLAB_MOCK_ISSUE_STATE="closed"
run_wip "$REPO_GL" abandon 51
if [ "$LAST_RC" -eq 1 ] && state_has 51 "status:wip"; then
    pass "G2b: abandon closed #51 → exit 1, labels unchanged"
else
    fail "G2b: expected exit 1 + status:wip retained (rc=$LAST_RC) state=[$(cat "$GLAB_STATE_DIR/labels-51" 2>/dev/null | tr '\n' ',')] err=[$LAST_ERR]"
fi

# G2c: unknown/indeterminate state → abandon refuses (exit 1), labels untouched.
reset_logs; reset_state
seed_labels 52 "status:wip"
export GLAB_MOCK_ISSUE_STATE="mystery"
run_wip "$REPO_GL" abandon 52
if [ "$LAST_RC" -eq 1 ] && state_has 52 "status:wip"; then
    pass "G2c: abandon unknown-state #52 → exit 1, labels unchanged"
else
    fail "G2c: expected exit 1 + status:wip retained (rc=$LAST_RC) state=[$(cat "$GLAB_STATE_DIR/labels-52" 2>/dev/null | tr '\n' ',')] err=[$LAST_ERR]"
fi

# G2d (guard): abandon rejects --session-id with exit 2 (verb does not consume a
# session id). Documents the CLI contract the primary abandon cases rely on.
reset_logs; reset_state
seed_labels 53 "status:wip"
export GLAB_MOCK_ISSUE_STATE="opened"
run_wip "$REPO_GL" abandon 53 --session-id "$SID_A"
if [ "$LAST_RC" -eq 2 ] && state_has 53 "status:wip"; then
    pass "G2d: abandon --session-id → exit 2, no label change"
else
    fail "G2d: expected exit 2 + status:wip retained (rc=$LAST_RC) state=[$(cat "$GLAB_STATE_DIR/labels-53" 2>/dev/null | tr '\n' ',')] err=[$LAST_ERR]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
