#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-set.sh, bin/github-issues/wip-state/cmd-check.sh, bin/github-issues/wip-state/cmd-clear.sh
# Tags: scope:issue-specific, gitlab, forge, wip-state, TL2
set -u

# Issue #2308 — GitLab WIP signaling in wip-state.sh. TDD RED: wip-state.sh has
# no GitLab branch yet (it drives GitHub Projects v2 via gh). A gitlab-origin
# repo must instead signal WIP through glab labels (status:wip / status:done).
# glab and gh are mocked as extensionless bash scripts on PATH (bash-to-bash
# lookup, reliable on Windows); no real forge API is hit.
#
# # TL3 gap
#   - Real `glab` label create/update against live GitLab (auth, label
#     idempotency, issue-not-found) is not exercised here.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"

TARGET="$AGENTS_DIR/bin/github-issues/wip-state.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Isolated fixture config dir (no .env → no host-config contamination). Derived
# under the temp root, never a hardcoded path. Plans dir dual-pinned per
# rules/test/fixture-isolation.md; inherited session ids cleared so the helper
# resolves the fixture, never this live session.
FIX_CFG="$TMPROOT/config"
mkdir -p "$FIX_CFG"
export AGENTS_CONFIG_DIR="$FIX_CFG"
export WORKFLOW_PLANS_DIR="$TMPROOT/plans"
export CLAUDE_WORKFLOW_DIR="$TMPROOT/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
# Drop any inherited WIP_STATE_* so D5's "missing required env vars" path is real.
unset WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
      WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
      WIP_STATE_FINGERPRINT_FIELD_ID 2>/dev/null || true

SID="sid-2308-fixture"

# Mock bin: glab is a STATEFUL label store (logs argv to GLAB_MOCK_LOG, applies
# --label/--unlabel to a per-issue label set under GLAB_STATE_DIR, and answers
# `--json labels` from that set) so set/clear replacement and check read-back are
# provable, not just log-greppable. gh logs argv to GH_MOCK_LOG and fails every
# call (resolver miss → no Projects v2 side effects).
MOCK_BIN="$TMPROOT/mock-bin"
mkdir -p "$MOCK_BIN"
GLAB_LOG="$TMPROOT/glab.log"
GH_LOG="$TMPROOT/gh.log"
GLAB_STATE_DIR="$TMPROOT/glab-state"
mkdir -p "$GLAB_STATE_DIR"
export GLAB_MOCK_LOG="$GLAB_LOG"
export GH_MOCK_LOG="$GH_LOG"
export GLAB_STATE_DIR

cat > "$MOCK_BIN/glab" <<'GLABEOF'
#!/bin/bash
# Stateful glab mock. Records argv; maintains a per-issue label set so that
# `--label`/`--unlabel` (and `--remove-label`) mutate state and `--json labels`
# reads it back. Any argument matching status:wip / status:done is treated as a
# label token; the first pure-digit argument selects the issue's state file.
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
    *"--json labels"*|*"--json"*"labels"*)
        # Emit the current label set as a gh/glab-style JSON labels array.
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

# run_wip <repo> <arg...> : run wip-state.sh from inside the repo with mocks on
# PATH. Captures stdout to $LAST_OUT, stderr to $LAST_ERR and rc to $LAST_RC.
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

log_has() { grep -qi -- "$2" "$1" 2>/dev/null; }

echo "=== Group D: wip-state.sh GitLab routing (mocked glab/gh) ==="

REPO_GL="$(make_repo 'git@gitlab.com:acme/widgets.git')"
REPO_GH="$(make_repo 'git@github.com:acme/widgets.git')"

# D1-D3b: set/check/clear chain on gitlab (stateful — must run together)
case_begin "d-gitlab-set-check-clear-chain" "bin/github-issues/wip-state/cmd-set.sh"
reset_logs; reset_state
seed_labels 42 "status:done"
run_wip "$REPO_GL" set 42 --session-id "$SID"
if [ "$LAST_RC" -eq 0 ] \
   && log_has "$GLAB_LOG" "status:wip" && log_has "$GLAB_LOG" "42" \
   && state_has 42 "status:wip" && ! state_has 42 "status:done" \
   && [ ! -s "$GH_LOG" ]; then
    pass "D1: gitlab set → exit 0, status:wip applied and status:done replaced for #42, gh NOT called"
else
    fail "D1: expected exit 0 + status:wip set / status:done cleared + no gh (rc=$LAST_RC) glab-log=[$(cat "$GLAB_LOG" 2>/dev/null)] gh-log=[$(cat "$GH_LOG" 2>/dev/null)] state=[$(cat "$GLAB_STATE_DIR/labels-42" 2>/dev/null | tr '\n' ',')]"
fi
reset_logs
run_wip "$REPO_GL" check 42 --session-id "$SID"
if [ "$LAST_RC" -eq 0 ] && [ -s "$GLAB_LOG" ] && log_has "$GLAB_LOG" "42" \
   && printf '%s' "$LAST_OUT" | grep -qE '^(same|other)$' \
   && [ ! -s "$GH_LOG" ]; then
    pass "D2: gitlab check → glab queried for #42, reports WIP, exit 0, gh NOT called"
else
    fail "D2: expected exit 0 + glab query + WIP output + no gh (rc=$LAST_RC) out=[$LAST_OUT] glab-log=[$(cat "$GLAB_LOG" 2>/dev/null)] gh-log=[$(cat "$GH_LOG" 2>/dev/null)]"
fi
reset_logs
run_wip "$REPO_GL" clear 42
if [ "$LAST_RC" -eq 0 ] \
   && log_has "$GLAB_LOG" "status:done" && log_has "$GLAB_LOG" "42" \
   && state_has 42 "status:done" && ! state_has 42 "status:wip" \
   && [ ! -s "$GH_LOG" ]; then
    pass "D3: gitlab clear → exit 0, status:done applied and status:wip replaced for #42, gh NOT called"
else
    fail "D3: expected exit 0 + status:done set / status:wip cleared + no gh (rc=$LAST_RC) glab-log=[$(cat "$GLAB_LOG" 2>/dev/null)] gh-log=[$(cat "$GH_LOG" 2>/dev/null)] state=[$(cat "$GLAB_STATE_DIR/labels-42" 2>/dev/null | tr '\n' ',')]"
fi
reset_logs
run_wip "$REPO_GL" check 42 --session-id "$SID"
if [ "$LAST_RC" -eq 0 ] && printf '%s' "$LAST_OUT" | grep -qxE 'none'; then
    pass "D3b: gitlab check after clear → outputs 'none', exit 0"
else
    fail "D3b: expected exit 0 + non-WIP output (rc=$LAST_RC) out=[$LAST_OUT]"
fi
case_end

# D4: gitlab repo + cross-repo --repo → rejected with exit 2.
case_begin "d4-gitlab-cross-repo-rejection" "bin/github-issues/wip-state/cmd-check.sh"
reset_logs
run_wip "$REPO_GL" set 42 --session-id "$SID" --repo other/project
if [ "$LAST_RC" -eq 2 ] && ! printf '%s' "$LAST_ERR" | grep -qi "missing required env vars"; then
    pass "D4: gitlab + --repo → exit 2, not the missing-env path"
else
    fail "D4: expected exit 2 without missing-env msg (rc=$LAST_RC) err=[$LAST_ERR]"
fi
case_end

# D5: CONTROL — github repo with no WIP_STATE_* env → gh path (regression pin).
case_begin "d5-github-control" "bin/github-issues/wip-state/cmd-clear.sh"
reset_logs
run_wip "$REPO_GH" set 42 --session-id "$SID"
if [ "$LAST_RC" -eq 2 ] \
   && printf '%s' "$LAST_ERR" | grep -qi "missing required env vars" \
   && [ ! -s "$GLAB_LOG" ]; then
    pass "D5: github set → gh path (missing-env exit 2), glab NOT called"
else
    fail "D5: expected gh missing-env exit 2 + no glab (rc=$LAST_RC) glab-log=[$(cat "$GLAB_LOG" 2>/dev/null)] err=[$LAST_ERR]"
fi
case_end

# D6: unknown-forge guard — neither gh nor glab invoked.
case_begin "d6-unknown-forge" "bin/github-issues/wip-state.sh"
REPO_UNK="$(make_repo 'git@bitbucket.org:acme/widgets.git')"
reset_logs; reset_state
run_wip "$REPO_UNK" set 42 --session-id "$SID"
if [ "$LAST_RC" -ne 0 ] && [ ! -s "$GLAB_LOG" ] && [ ! -s "$GH_LOG" ]; then
    pass "D6: unknown-forge repo → rejected (rc!=0), neither gh nor glab called"
else
    fail "D6: expected rc!=0 + no gh/glab calls (rc=$LAST_RC) gh-log=[$(cat "$GH_LOG" 2>/dev/null)] glab-log=[$(cat "$GLAB_LOG" 2>/dev/null)]"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
