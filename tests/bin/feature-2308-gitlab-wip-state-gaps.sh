#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/gitlab.sh
# Tags: scope:issue-specific, gitlab, wip-state, forge, TL2, session-id
set -u

# Issue #2308 — GitLab WIP verb (gitlab.sh) gaps unreached by
# feature-2308-gitlab-wip-state.sh: Gap 1 = gl_cmd_check "other" (status:wip
# present but stored wip-fp mismatches the checking session — the sibling reuses
# one SID so this branch never runs); Gap 2 = gl_cmd_abandon (open→remove labels;
# closed/unknown→exit 1) plus its `api .../issues/<N> --jq .state` read the
# sibling glab mock does not answer. glab/gh mocked as PATH scripts, no real API.
# #2925 gl-* cases: raw-sid label, set replaces every other wip-fp:*, invalid sid / read failure change nothing.
# # TL3 gap — real glab label/state calls and one-edit add/remove atomicity not exercised.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TARGET="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Isolated fake agents main root (no .env). Plans dir dual-pinned per
# rules/test/fixture-isolation.md; inherited session ids cleared.
FAKE_MAIN_ROOT="$TMPROOT/fake-main-root"
mkdir -p "$FAKE_MAIN_ROOT"
export AGENTS_MAIN_ROOT="$FAKE_MAIN_ROOT"
export WORKFLOW_PLANS_DIR="$TMPROOT/plans"
export WORKFLOW_STATE_DIR="$TMPROOT/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
      WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
      WIP_STATE_SESSION_ID_FIELD_ID 2>/dev/null || true

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
# GLAB_MOCK_ISSUE_STATE; GLAB_MOCK_LABELS_FAIL=1 makes the `--json labels` read fail.
printf '%s\n' "$*" >> "$GLAB_MOCK_LOG"
case "$*" in
    *"--json labels"*) [ "${GLAB_MOCK_LABELS_FAIL:-0}" = "1" ] && exit 1 ;;
esac

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
reset_all() { reset_logs; reset_state; unset GLAB_MOCK_LABELS_FAIL; }
state_of() { tr '\n' ',' < "$GLAB_STATE_DIR/labels-$1" 2>/dev/null; }
n_fp() { grep -c '^wip-fp:' "$GLAB_STATE_DIR/labels-$1" 2>/dev/null || true; }
n_edits() { grep -c '^issue edit' "$GLAB_LOG" 2>/dev/null || true; }

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

echo "=== Gap 1: gl_cmd_check other / same fingerprint routing ==="
case_begin "g1-check-token-routing" "bin/github-issues/wip-state/gitlab.sh"

# G1-setup: set 42 with session A → status:wip + wip-fp:<hashA> applied.
reset_logs; reset_state
run_wip "$REPO_GL" set 42 --session-id "$SID_A"
if [ "$LAST_RC" -eq 0 ] && state_has 42 "status:wip"; then
    pass "G1-setup: set 42 (session A) → exit 0, status:wip applied"
else
    fail "G1-setup: expected exit 0 + status:wip (rc=$LAST_RC) state=[$(cat "$GLAB_STATE_DIR/labels-42" 2>/dev/null | tr '\n' ',')] err=[$LAST_ERR]"
fi

# G1a (primary): check 42 with a DIFFERENT session B → status:wip present but the
# stored fingerprint is session A's → mismatch → "other" (#2408: same token as GitHub).
reset_logs
run_wip "$REPO_GL" check 42 --session-id "$SID_B"
if [ "$LAST_RC" -eq 0 ] && [ "$LAST_OUT" = "other" ]; then
    pass "G1a: check 42 (session B) → other, exit 0"
else
    fail "G1a: expected 'other' + exit 0 (rc=$LAST_RC) out=[$LAST_OUT] err=[$LAST_ERR]"
fi

# G1b (positive control): check 42 with the SAME session A → fingerprint matches
# → "same". Proves the verdict is fingerprint-driven, not constant.
reset_logs
run_wip "$REPO_GL" check 42 --session-id "$SID_A"
if [ "$LAST_RC" -eq 0 ] && [ "$LAST_OUT" = "same" ]; then
    pass "G1b: check 42 (session A) → same, exit 0"
else
    fail "G1b: expected 'same' + exit 0 (rc=$LAST_RC) out=[$LAST_OUT] err=[$LAST_ERR]"
fi
case_end

echo ""
echo "=== Gap 2: gl_cmd_abandon (open→remove labels; closed/unknown→exit 1) ==="
case_begin "g2-abandon-verb" "bin/github-issues/wip-state/gitlab.sh"

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
case_end

echo ""
echo "=== #2925: raw session id in the wip-fp label ==="
SID_2925_A="sid-2925-A"
SID_2925_B="sid-2925-B"

# set: raw sid label applied; EVERY stale wip-fp:* and status:done dropped in ONE edit.
case_begin "gl-set-raw-sid-replaces-stale-fp" "bin/github-issues/wip-state/gitlab.sh"
reset_all
seed_labels 142 "status:done" "wip-fp:deadbeef" "wip-fp:cafebabe" "wip-fp:$SID_2925_B"
run_wip "$REPO_GL" set 142 --session-id "$SID_2925_A"
if [ "$LAST_RC" -eq 0 ] && state_has 142 "wip-fp:$SID_2925_A" && state_has 142 "status:wip" \
   && [ "$(n_fp 142)" = "1" ] && ! state_has 142 "wip-fp:deadbeef" && ! state_has 142 "wip-fp:cafebabe" \
   && ! state_has 142 "wip-fp:$SID_2925_B" && ! state_has 142 "status:done" \
   && [ "$(n_edits)" = "1" ] && [ ! -s "$GH_LOG" ]; then
    pass "GL1: set → wip-fp:<raw sid> + status:wip; all 3 stale wip-fp:* and status:done removed in one edit"
else
    fail "GL1: rc=$LAST_RC edits=$(n_edits) state=[$(state_of 142)] err=[$LAST_ERR] log=[$(cat "$GLAB_LOG")]"
fi
case_end

# set twice with the same sid: still exactly one wip-fp label, rc 0.
case_begin "gl-set-same-sid-idempotent" "bin/github-issues/wip-state/gitlab.sh"
reset_all
seed_labels 143 "status:done"
run_wip "$REPO_GL" set 143 --session-id "$SID_2925_A"
RC1=$LAST_RC
run_wip "$REPO_GL" set 143 --session-id "$SID_2925_A"
if [ "$RC1" -eq 0 ] && [ "$LAST_RC" -eq 0 ] && [ "$(n_fp 143)" = "1" ] && state_has 143 "wip-fp:$SID_2925_A"; then
    pass "GL2: repeated set with the same sid → idempotent (one wip-fp:<sid>)"
else
    fail "GL2: rc1=$RC1 rc2=$LAST_RC state=[$(state_of 143)] err=[$LAST_ERR]"
fi
case_end

# set when the label read fails: no edit at all, exit 1, named error.
case_begin "gl-set-label-read-fails-no-edit" "bin/github-issues/wip-state/gitlab.sh"
reset_all
seed_labels 144 "status:done" "wip-fp:deadbeef"
export GLAB_MOCK_LABELS_FAIL=1
run_wip "$REPO_GL" set 144 --session-id "$SID_2925_A"
if [ "$LAST_RC" -eq 1 ] && [ "$(n_edits)" = "0" ] \
   && printf '%s' "$LAST_ERR" | grep -qF "label read failed for #144" \
   && state_has 144 "wip-fp:deadbeef" && ! state_has 144 "status:wip"; then
    pass "GL3: label read failure → exit 1, no issue edit, labels unchanged"
else
    fail "GL3: rc=$LAST_RC edits=$(n_edits) state=[$(state_of 144)] err=[$LAST_ERR]"
fi
unset GLAB_MOCK_LABELS_FAIL
case_end

# check compares the raw sid: same for A, other for B and for a legacy 8-hex digest.
case_begin "gl-check-raw-sid-same-other" "bin/github-issues/wip-state/gitlab.sh"
reset_all
LEGACY_FP="$(printf '%s:%s' "$SID_2925_A" 145 | sha256sum | cut -c1-8)"
seed_labels 145 "status:wip" "wip-fp:$SID_2925_A"
run_wip "$REPO_GL" check 145 --session-id "$SID_2925_A"
OUT_A="$LAST_OUT" RC_A=$LAST_RC
run_wip "$REPO_GL" check 145 --session-id "$SID_2925_B"
OUT_B="$LAST_OUT" RC_B=$LAST_RC
seed_labels 145 "status:wip" "wip-fp:$LEGACY_FP"
run_wip "$REPO_GL" check 145 --session-id "$SID_2925_A"
if [ "$RC_A" -eq 0 ] && [ "$OUT_A" = "same" ] && [ "$RC_B" -eq 0 ] && [ "$OUT_B" = "other" ] \
   && [ "$LAST_RC" -eq 0 ] && [ "$LAST_OUT" = "other" ]; then
    pass "GL4: check → same for wip-fp:<own sid>, other for another sid and for the legacy digest"
else
    fail "GL4: A=[$RC_A/$OUT_A] B=[$RC_B/$OUT_B] legacy=[$LAST_RC/$LAST_OUT] err=[$LAST_ERR]"
fi
case_end

# two wip-fp labels (one of them ours) → other, never same.
case_begin "gl-check-two-fp-labels-other" "bin/github-issues/wip-state/gitlab.sh"
reset_all
seed_labels 146 "status:wip" "wip-fp:$SID_2925_A" "wip-fp:$SID_2925_B"
run_wip "$REPO_GL" check 146 --session-id "$SID_2925_A"
if [ "$LAST_RC" -eq 0 ] && [ "$LAST_OUT" = "other" ]; then
    pass "GL5: two wip-fp:* labels → other even for a matching sid"
else
    fail "GL5: rc=$LAST_RC out=[$LAST_OUT] err=[$LAST_ERR]"
fi
case_end

# a resolved sid outside [A-Za-z0-9_-] (comma) → set and check exit 1, no label change.
# --session-id is charset-checked at parse time (exit 2), so the bad value comes from a stub
# bin/resolve-session-id in a copied checkout (the bridge path).
case_begin "gl-invalid-sid-set-check-exit-1" "bin/github-issues/wip-state.sh"
reset_all
FAKE_CO="$TMPROOT/fake-co"
mkdir -p "$FAKE_CO/hooks"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin" "$FAKE_CO/bin"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks/lib" "$FAKE_CO/hooks/lib"
printf '#!/bin/bash\nprintf "%%s" "bad,sid"\n' > "$FAKE_CO/bin/resolve-session-id"
REAL_TARGET="$TARGET"
TARGET="$FAKE_CO/bin/github-issues/wip-state.sh"
seed_labels 147 "status:done"
run_wip "$REPO_GL" set 147
RC_S=$LAST_RC ERR_S="$LAST_ERR" EDITS_S=$(n_edits)
seed_labels 147 "status:wip" "wip-fp:bad,sid"
run_wip "$REPO_GL" check 147
TARGET="$REAL_TARGET"
if [ "$RC_S" -eq 1 ] && [ "$EDITS_S" = "0" ] && printf '%s' "$ERR_S" | grep -qF "invalid session id for label" \
   && [ "$LAST_RC" -eq 1 ] && [ "$(n_edits)" = "0" ] && [ "$LAST_OUT" != "same" ]; then
    pass "GL6: invalid sid → set/check exit 1 with the named error, no issue edit"
else
    fail "GL6: set=[$RC_S edits=$EDITS_S err=$ERR_S] check=[$LAST_RC out=$LAST_OUT edits=$(n_edits) err=$LAST_ERR]"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
