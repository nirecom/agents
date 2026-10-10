#!/usr/bin/env bash
# tests/bin/feature-2434-worker-payload-cli.sh
# Tests: bin/worker-dispatch-payload
# Tags: worker-dispatch, payload-cli, TL1, TL2, scope:issue-specific
#
# Issue #2434 — bin/worker-dispatch-payload is the sole authorized writer for
# worker payload files into the control directory.
#
# The implementation does NOT exist yet; every case fails cleanly when the CLI
# is absent (pattern: check `[ -f "$CLI" ]` then `fail "not implemented"`).
# Existing-behaviour cases: none (new CLI, nothing to preserve today).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# harness.sh assert_eq is 2-arg (actual, expected); override with 3-arg (name, expected, actual).
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

CLI="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch-payload"
PAYLOAD_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/payload.js"
DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"

# Read MAX_PAYLOAD_BYTES from payload.js (fall back to 4 MiB if file absent)
MAX_PB="$(node -e 'try{console.log(require(process.argv[1]).MAX_PAYLOAD_BYTES)}catch(e){console.log(4194304)}' "$(np "$PAYLOAD_JS")" 2>/dev/null)"
: "${MAX_PB:=4194304}"

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT

harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPD/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

SID="test2434pld"
CTRL="$WORKFLOW_STATE_DIR/$SID.control"
P_DIR="$WORKFLOW_PLANS_DIR"

# ---------------------------------------------------------------------------
# Helper: write a draft JSON file and return its np()-normalized path
# Usage: draft_path=$(mk_draft <worker> <seq> <json>)
# ---------------------------------------------------------------------------
mk_draft() {
    local worker="$1" seq="$2" json="$3"
    local fname="$SID-worker-$worker-$seq.draft.json"
    printf '%s' "$json" > "$P_DIR/$fname"
    np "$P_DIR/$fname"
}

# Rejected-publish contract (C10): the draft stays byte-identical, so a
# rejection can never eat or rewrite the model's input. snap_draft saves the
# bytes before the CLI runs; draft_unchanged compares them afterwards.
snap_draft() { cp "$1" "$TMPD/$(basename "$1").orig"; }
draft_unchanged() { # <label> <draft-path>
    if [ -f "$2" ] && cmp -s "$TMPD/$(basename "$2").orig" "$2"; then pass "$1"
    else fail "$1" "rejected draft was removed or altered"; fi
}

# Outcome is all-or-nothing for any accepted --seq value: exit 0 means the
# payload is published at the seq-derived name and the draft is gone; exit
# 1/2 means no payload and a byte-identical draft. Any other exit is a crash.
seq_outcome() { # <label> <rc> <draft-path> <payload-path>
    local L="$1" RC="$2" D="$3" P="$4"
    case "$RC" in
        0)
            if [ -f "$P" ]; then pass "$L/accepted-payload-published"
            else fail "$L/accepted-payload-published" "exit 0 but no $P"; fi
            if [ ! -f "$D" ]; then pass "$L/accepted-draft-consumed"
            else fail "$L/accepted-draft-consumed" "exit 0 but draft still present"; fi ;;
        1|2)
            if [ ! -f "$P" ]; then pass "$L/rejected-no-payload"
            else fail "$L/rejected-no-payload" "exit $RC but payload published"; fi
            draft_unchanged "$L/rejected-draft-byte-identical" "$D" ;;
        *) fail "$L/exit-in-contract" "exit $RC is outside {0,1,2}" ;;
    esac
}

# == 1. publish-valid-draft ==
# A valid draft → exit 0, draft deleted, stdout PAYLOAD=<abs>, payload in control dir,
# JSON content identical to what was in the draft.
BASIC_JSON='{"phase":"initial","issue_number":1}'
D1="$(mk_draft issue-close-finalize 1 "$BASIC_JSON")"
if [ -f "$CLI" ]; then
    CLI_OUT="$(node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 1 --draft "$D1" 2>/dev/null)" ; CLI_RC=$?
    assert_eq "publish/exit-0" "0" "$CLI_RC"
    case "$CLI_OUT" in
        PAYLOAD=*) pass "publish/stdout-has-PAYLOAD" ;;
        *) fail "publish/stdout-has-PAYLOAD" "got: $(printf '%q' "$CLI_OUT")" ;;
    esac
    PUBLISHED="${CLI_OUT#PAYLOAD=}"
    if [ -f "$PUBLISHED" ]; then pass "publish/payload-file-exists"
    else fail "publish/payload-file-exists" "path=$PUBLISHED"; fi
    # draft must be deleted
    D1_POSIX="$(np "$P_DIR/$SID-worker-issue-close-finalize-1.draft.json" 2>/dev/null || echo "$P_DIR/$SID-worker-issue-close-finalize-1.draft.json")"
    if [ ! -f "$P_DIR/$SID-worker-issue-close-finalize-1.draft.json" ]; then pass "publish/draft-deleted"
    else fail "publish/draft-deleted" "draft still present"; fi
    # payload must be under control dir; both sides in one spelling (node prints C:/, bash holds /c/ or /tmp).
    case "$(np "$PUBLISHED")" in
        "$(np "$CTRL")/"*) pass "publish/payload-in-control-dir" ;;
        *) fail "publish/payload-in-control-dir" "path=$PUBLISHED ctrl=$CTRL" ;;
    esac
    # JSON content must equal the original draft
    GOT_CONTENT="$(cat "$PUBLISHED" 2>/dev/null || echo MISSING)"
    assert_eq "publish/payload-content-identical" "$BASIC_JSON" "$GOT_CONTENT"
else
    fail "publish/exit-0" "not implemented: bin/worker-dispatch-payload absent"
    fail "publish/stdout-has-PAYLOAD" "not implemented"
    fail "publish/payload-file-exists" "not implemented"
    fail "publish/draft-deleted" "not implemented"
    fail "publish/payload-in-control-dir" "not implemented"
    fail "publish/payload-content-identical" "not implemented"
    PUBLISHED=""
fi

# == 2. second-publish-same-seq ==
# Re-publishing same seq → exit 1 and existing payload byte-identical
if [ -f "$CLI" ]; then
    D2="$(mk_draft issue-close-finalize 1 "$BASIC_JSON")"
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 1 --draft "$D2" >/dev/null 2>&1 ; RC2=$?
    assert_eq "second-publish/exit-1" "1" "$RC2"
    # Original published payload must be unchanged
    if [ -n "$PUBLISHED" ] && [ -f "$PUBLISHED" ]; then
        GOT2="$(cat "$PUBLISHED")"
        assert_eq "second-publish/payload-unchanged" "$BASIC_JSON" "$GOT2"
    fi
else
    fail "second-publish/exit-1" "not implemented"
fi

# == 3. publish-after-dispatched ==
# .dispatched marker present → exit 1
mkdir -p "$CTRL"
touch "$CTRL/worker-issue-close-finalize-9.dispatched"
D3="$(mk_draft issue-close-finalize 9 "$BASIC_JSON")"
snap_draft "$P_DIR/$SID-worker-issue-close-finalize-9.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 9 --draft "$D3" >/dev/null 2>&1 ; RC3=$?
    assert_eq "after-dispatched/exit-1" "1" "$RC3"
    draft_unchanged "after-dispatched/draft-intact" "$P_DIR/$SID-worker-issue-close-finalize-9.draft.json"
    if [ ! -f "$CTRL/worker-issue-close-finalize-9.json" ]; then pass "after-dispatched/no-control-payload"
    else fail "after-dispatched/no-control-payload" "payload published after the .dispatched marker"; fi
else
    fail "after-dispatched/exit-1" "not implemented"
    fail "after-dispatched/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "after-dispatched/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$P_DIR/$SID-worker-issue-close-finalize-9.draft.json"

# == 4. reject: unknown key ==
printf '%s' '{"phase":"initial","issue_number":1,"_unknown_xyz":true}' > "$P_DIR/$SID-worker-issue-close-finalize-10.draft.json"
snap_draft "$P_DIR/$SID-worker-issue-close-finalize-10.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 10 --draft "$(np "$P_DIR/$SID-worker-issue-close-finalize-10.draft.json")" >/dev/null 2>&1 ; RC4=$?
    assert_eq "reject/unknown-key/exit-1" "1" "$RC4"
    # C10: rejected draft must remain byte-identical; no control payload published.
    draft_unchanged "reject/unknown-key/draft-intact" "$P_DIR/$SID-worker-issue-close-finalize-10.draft.json"
    if [ ! -f "$CTRL/worker-issue-close-finalize-10.json" ]; then pass "reject/unknown-key/no-control-payload"
    else fail "reject/unknown-key/no-control-payload" "control payload published despite rejection"; fi
else
    fail "reject/unknown-key/exit-1" "not implemented"
    fail "reject/unknown-key/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "reject/unknown-key/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$P_DIR/$SID-worker-issue-close-finalize-10.draft.json"

# == 5. reject: non-JSON ==
printf 'not-a-json-object' > "$P_DIR/$SID-worker-issue-close-finalize-11.draft.json"
snap_draft "$P_DIR/$SID-worker-issue-close-finalize-11.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 11 --draft "$(np "$P_DIR/$SID-worker-issue-close-finalize-11.draft.json")" >/dev/null 2>&1 ; RC5=$?
    assert_eq "reject/non-json/exit-1" "1" "$RC5"
    draft_unchanged "reject/non-json/draft-intact" "$P_DIR/$SID-worker-issue-close-finalize-11.draft.json"
    if [ ! -f "$CTRL/worker-issue-close-finalize-11.json" ]; then pass "reject/non-json/no-control-payload"
    else fail "reject/non-json/no-control-payload" "control payload published despite rejection"; fi
else
    fail "reject/non-json/exit-1" "not implemented"
    fail "reject/non-json/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "reject/non-json/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$P_DIR/$SID-worker-issue-close-finalize-11.draft.json"

# == 6. reject: oversize (> MAX_PAYLOAD_BYTES) ==
OVER_DRAFT="$P_DIR/$SID-worker-issue-close-finalize-12.draft.json"
node -e "
const fs=require('fs'),n=parseInt(process.argv[1])+1;
fs.writeFileSync(process.argv[2],Buffer.alloc(n,'x'));
" "$MAX_PB" "$(np "$OVER_DRAFT")" 2>/dev/null
[ -f "$OVER_DRAFT" ] && snap_draft "$OVER_DRAFT"
if [ -f "$CLI" ] && [ -f "$OVER_DRAFT" ]; then
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 12 --draft "$(np "$OVER_DRAFT")" >/dev/null 2>&1 ; RC6=$?
    assert_eq "reject/oversize/exit-1" "1" "$RC6"
    draft_unchanged "reject/oversize/draft-intact" "$OVER_DRAFT"
    if [ ! -f "$CTRL/worker-issue-close-finalize-12.json" ]; then pass "reject/oversize/no-control-payload"
    else fail "reject/oversize/no-control-payload" "oversize payload published"; fi
elif [ ! -f "$CLI" ]; then
    fail "reject/oversize/exit-1" "not implemented"
    fail "reject/oversize/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "reject/oversize/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
else
    skip "reject/oversize — could not create oversize file"
fi
rm -f "$OVER_DRAFT"

# == 7. reject: unregistered worker ==
printf '%s' '{"cwd":"/tmp","timeout_seconds":30}' > "$P_DIR/$SID-worker-no-such-worker-1.draft.json"
snap_draft "$P_DIR/$SID-worker-no-such-worker-1.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker no-such-worker --seq 1 --draft "$(np "$P_DIR/$SID-worker-no-such-worker-1.draft.json")" >/dev/null 2>&1 ; RC7=$?
    assert_eq "reject/unregistered-worker/exit-1" "1" "$RC7"
    draft_unchanged "reject/unregistered-worker/draft-intact" "$P_DIR/$SID-worker-no-such-worker-1.draft.json"
    if [ ! -f "$CTRL/worker-no-such-worker-1.json" ]; then pass "reject/unregistered-worker/no-control-payload"
    else fail "reject/unregistered-worker/no-control-payload" "control payload published despite rejection"; fi
else
    fail "reject/unregistered-worker/exit-1" "not implemented"
    fail "reject/unregistered-worker/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "reject/unregistered-worker/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$P_DIR/$SID-worker-no-such-worker-1.draft.json"

# == 8. reject: draft name/arg mismatch ==
# Draft is for issue-close-finalize but CLI --worker says commit-push
printf '%s' '{"phase":"initial","issue_number":1}' > "$P_DIR/$SID-worker-issue-close-finalize-20.draft.json"
snap_draft "$P_DIR/$SID-worker-issue-close-finalize-20.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker commit-push --seq 20 --draft "$(np "$P_DIR/$SID-worker-issue-close-finalize-20.draft.json")" >/dev/null 2>&1 ; RC8=$?
    assert_eq "reject/name-mismatch/exit-1" "1" "$RC8"
    draft_unchanged "reject/name-mismatch/draft-intact" "$P_DIR/$SID-worker-issue-close-finalize-20.draft.json"
    # C10: neither worker arg nor draft worker name should produce a control payload.
    if [ ! -f "$CTRL/worker-commit-push-20.json" ] && [ ! -f "$CTRL/worker-issue-close-finalize-20.json" ]; then
        pass "reject/name-mismatch/no-control-payload"
    else
        fail "reject/name-mismatch/no-control-payload" "control payload published despite name-mismatch rejection"
    fi
else
    fail "reject/name-mismatch/exit-1" "not implemented"
    fail "reject/name-mismatch/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "reject/name-mismatch/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$P_DIR/$SID-worker-issue-close-finalize-20.draft.json"

# == 9. reject: draft outside PLANS_DIR ==
printf '%s' '{"phase":"initial","issue_number":1}' > "$TMPD/outside.draft.json"
snap_draft "$TMPD/outside.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 21 --draft "$(np "$TMPD/outside.draft.json")" >/dev/null 2>&1 ; RC9=$?
    assert_eq "reject/outside-plansdir/exit-1" "1" "$RC9"
    draft_unchanged "reject/outside-plansdir/draft-intact" "$TMPD/outside.draft.json"
    if [ ! -f "$CTRL/worker-issue-close-finalize-21.json" ]; then pass "reject/outside-plansdir/no-control-payload"
    else fail "reject/outside-plansdir/no-control-payload" "payload published from a draft outside PLANS_DIR"; fi
else
    fail "reject/outside-plansdir/exit-1" "not implemented"
    fail "reject/outside-plansdir/draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "reject/outside-plansdir/no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi

# == 9b. reject: in-PLANS symlink to an outside draft ==
# The lexical path is inside PLANS_DIR and the name matches the seq, so only a
# realpath check catches it. A rejection leaves the link, its target and the
# control directory untouched. MSYS `ln -s` may fall back to a copy; skip then.
SYM_TARGET="$TMPD/outside-target.draft.json"
SYM_LINK="$P_DIR/$SID-worker-issue-close-finalize-22.draft.json"
printf '%s' '{"phase":"initial","issue_number":1}' > "$SYM_TARGET"
snap_draft "$SYM_TARGET"
CTRL_BEFORE="$(ls -A "$CTRL" 2>/dev/null | tr '\n' ' ')"
ln -s "$SYM_TARGET" "$SYM_LINK" 2>/dev/null
# Git Bash copies by default; ask for a native link (needs Developer Mode or admin).
if [ ! -L "$SYM_LINK" ]; then
    rm -f "$SYM_LINK"
    MSYS=winsymlinks:nativestrict ln -s "$SYM_TARGET" "$SYM_LINK" 2>/dev/null
fi
if [ ! -L "$SYM_LINK" ]; then
    skip "reject/in-plans-symlink: symlinks unavailable on this host (ln -s did not create a link)"
elif [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 22 --draft "$(np "$SYM_LINK")" >/dev/null 2>&1 ; RC9B=$?
    assert_eq "reject/in-plans-symlink/exit-1" "1" "$RC9B"
    draft_unchanged "reject/in-plans-symlink/target-intact" "$SYM_TARGET"
    if [ -L "$SYM_LINK" ]; then pass "reject/in-plans-symlink/link-kept"
    else fail "reject/in-plans-symlink/link-kept" "the rejected symlink was consumed or replaced"; fi
    if [ ! -e "$CTRL/worker-issue-close-finalize-22.json" ]; then pass "reject/in-plans-symlink/no-control-payload"
    else fail "reject/in-plans-symlink/no-control-payload" "payload published through a symlink to an outside draft"; fi
    assert_eq "reject/in-plans-symlink/control-dir-unchanged" "$CTRL_BEFORE" "$(ls -A "$CTRL" 2>/dev/null | tr '\n' ' ')"
else
    fail "reject/in-plans-symlink/exit-1" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$SYM_LINK"

# == 10. reject: invalid sid (exit 2 — bad argument value, not payload validation) ==
# Note: ../x contains '/' and fails SESSION_ID_VALID_RE = ^[A-Za-z0-9_-]+$
# Plan Step 6-1: "引数の誤りは 2" — invalid --session value is an argument error.
printf '%s' '{"phase":"initial","issue_number":1}' > "$P_DIR/test-worker-issue-close-finalize-1.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "../x" --worker issue-close-finalize --seq 1 --draft "$(np "$P_DIR/test-worker-issue-close-finalize-1.draft.json")" >/dev/null 2>&1 ; RC10=$?
    assert_eq "reject/invalid-sid/exit-2" "2" "$RC10"
else
    fail "reject/invalid-sid/exit-2" "not implemented: bin/worker-dispatch-payload absent (expected exit 2 for bad --session arg)"
fi
rm -f "$P_DIR/test-worker-issue-close-finalize-1.draft.json"

# == 11. unknown-session works ==
# "unknown-session" satisfies SESSION_ID_VALID_RE (only alphanumeric + - _)
printf '%s' '{"phase":"initial","issue_number":1}' > "$P_DIR/unknown-session-worker-issue-close-finalize-1.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "unknown-session" --worker issue-close-finalize --seq 1 --draft "$(np "$P_DIR/unknown-session-worker-issue-close-finalize-1.draft.json")" >/dev/null 2>&1 ; RC11=$?
    assert_eq "unknown-session/exit-0" "0" "$RC11"
else
    fail "unknown-session/exit-0" "not implemented"
fi
rm -f "$P_DIR/unknown-session-worker-issue-close-finalize-1.draft.json"
rm -rf "$WORKFLOW_STATE_DIR/unknown-session.control"

# == 12. legacy state_file_path: matching PLANS basename → accepted, removed from payload ==
# Step 5-6 shim: state_file_path == PLANS path with matching basename → strip it, accept.
LEG_SID="test2434leg"
LEG_STATE_BASENAME="$LEG_SID-finalize-state-1.json"
LEG_PAYLOAD_JSON="{\"phase\":\"loop_step\",\"root_issue_number\":1,\"owner_repo\":\"o/r\",\"g5_decision\":\"recurse_done\",\"state_file_path\":\"$P_DIR/$LEG_STATE_BASENAME\"}"
printf '%s' "$LEG_PAYLOAD_JSON" > "$P_DIR/$LEG_SID-worker-issue-close-finalize-1.draft.json"
if [ -f "$CLI" ]; then
    LEG_OUT="$(node "$(np "$CLI")" --session "$LEG_SID" --worker issue-close-finalize --seq 1 --draft "$(np "$P_DIR/$LEG_SID-worker-issue-close-finalize-1.draft.json")" 2>/dev/null)" ; RC12=$?
    assert_eq "legacy-state-file/exit-0" "0" "$RC12"
    LEG_PUB="${LEG_OUT#PAYLOAD=}"
    if [ -f "$LEG_PUB" ]; then
        HAS_SF="$(node -e "try{const p=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.stdout.write(Object.prototype.hasOwnProperty.call(p,'state_file_path')?'yes':'no')}catch(e){process.stdout.write('err')}" "$(np "$LEG_PUB")" 2>/dev/null)"
        assert_eq "legacy-state-file/removed-from-published-payload" "no" "$HAS_SF"
    else
        fail "legacy-state-file/payload-exists" "path: $LEG_PUB"
    fi
else
    fail "legacy-state-file/exit-0" "not implemented"
    fail "legacy-state-file/removed-from-published-payload" "not implemented"
fi

# == 13. legacy state_file_path: mismatching value → exit 1 ==
MM_SID="test2434mm"
printf '%s' "{\"phase\":\"loop_step\",\"root_issue_number\":1,\"owner_repo\":\"o/r\",\"g5_decision\":\"recurse_done\",\"state_file_path\":\"/some/other/path.json\"}" > "$P_DIR/$MM_SID-worker-issue-close-finalize-1.draft.json"
snap_draft "$P_DIR/$MM_SID-worker-issue-close-finalize-1.draft.json"
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$MM_SID" --worker issue-close-finalize --seq 1 --draft "$(np "$P_DIR/$MM_SID-worker-issue-close-finalize-1.draft.json")" >/dev/null 2>&1 ; RC13=$?
    assert_eq "legacy-state-file/mismatch-exit-1" "1" "$RC13"
    draft_unchanged "legacy-state-file/mismatch-draft-intact" "$P_DIR/$MM_SID-worker-issue-close-finalize-1.draft.json"
    if [ ! -f "$WORKFLOW_STATE_DIR/$MM_SID.control/worker-issue-close-finalize-1.json" ]; then pass "legacy-state-file/mismatch-no-control-payload"
    else fail "legacy-state-file/mismatch-no-control-payload" "payload published despite a mismatched legacy state_file_path"; fi
else
    fail "legacy-state-file/mismatch-exit-1" "not implemented"
    fail "legacy-state-file/mismatch-draft-intact" "not implemented: bin/worker-dispatch-payload absent"
    fail "legacy-state-file/mismatch-no-control-payload" "not implemented: bin/worker-dispatch-payload absent"
fi
rm -f "$P_DIR/$MM_SID-worker-issue-close-finalize-1.draft.json"

# == 14. missing required arg → exit 2 ==
if [ -f "$CLI" ]; then
    node "$(np "$CLI")" --session "$SID" >/dev/null 2>&1 ; RC14=$?
    assert_eq "missing-required-arg/exit-2" "2" "$RC14"
else
    fail "missing-required-arg/exit-2" "not implemented"
fi

# == seq-edge: --seq zero, negative, nonnumeric, max-boundary ==
# C10: plan Step 6-1 defines exit 2 for argument errors ("引数の誤りは 2") but
# does not define a MAX_SEQ bound. Negative and nonnumeric values are argument
# errors (exit 2). Zero is treated as valid per the plan's silence; if the
# implementation rejects it, update this comment and expect exit 2 instead.
if [ -f "$CLI" ]; then
    D_NEG="$P_DIR/$SID-worker-issue-close-finalize-30.draft.json"
    printf '%s' '{"phase":"initial","issue_number":1}' > "$D_NEG"
    snap_draft "$D_NEG"
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq -1 --draft "$(np "$D_NEG")" >/dev/null 2>&1 ; RC_NEG=$?
    assert_eq "seq/negative/exit-2" "2" "$RC_NEG"
    draft_unchanged "seq/negative/draft-byte-identical" "$D_NEG"
    if [ -z "$(find "$CTRL" -name 'worker-issue-close-finalize--1*' 2>/dev/null)" ]; then pass "seq/negative/no-payload"
    else fail "seq/negative/no-payload" "payload published for --seq -1"; fi
    rm -f "$D_NEG"
else
    fail "seq/negative/exit-2" "implementation missing: bin/worker-dispatch-payload absent"
fi
if [ -f "$CLI" ]; then
    D_NAN="$P_DIR/$SID-worker-issue-close-finalize-31.draft.json"
    printf '%s' '{"phase":"initial","issue_number":1}' > "$D_NAN"
    snap_draft "$D_NAN"
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq abc --draft "$(np "$D_NAN")" >/dev/null 2>&1 ; RC_NAN=$?
    assert_eq "seq/nonnumeric/exit-2" "2" "$RC_NAN"
    draft_unchanged "seq/nonnumeric/draft-byte-identical" "$D_NAN"
    if [ ! -e "$CTRL/worker-issue-close-finalize-abc.json" ]; then pass "seq/nonnumeric/no-payload"
    else fail "seq/nonnumeric/no-payload" "payload published for --seq abc"; fi
    rm -f "$D_NAN"
else
    fail "seq/nonnumeric/exit-2" "implementation missing: bin/worker-dispatch-payload absent"
fi
if [ -f "$CLI" ]; then
    D_ZERO="$P_DIR/$SID-worker-issue-close-finalize-0.draft.json"
    printf '%s' '{"phase":"initial","issue_number":1}' > "$D_ZERO"
    snap_draft "$D_ZERO"
    node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq 0 --draft "$(np "$D_ZERO")" >/dev/null 2>&1 ; RC_ZERO=$?
    # The plan neither allows nor forbids seq=0, so either verdict is fine,
    # but it must be all-or-nothing (seq_outcome).
    seq_outcome "seq/zero" "$RC_ZERO" "$D_ZERO" "$CTRL/worker-issue-close-finalize-0.json"
    rm -f "$D_ZERO" "$CTRL/worker-issue-close-finalize-0.json" 2>/dev/null
else
    fail "seq/zero/exit-in-contract" "implementation missing: bin/worker-dispatch-payload absent"
fi
# MAX_SAFE_INTEGER (9007199254740991) and one past it: the plan defines no
# upper bound, so the verdict is open, but it must be all-or-nothing and the
# published name must carry the exact digits (no float rounding to ...992).
for BIG in 9007199254740991 9007199254740992; do
    if [ -f "$CLI" ]; then
        D_BIG="$P_DIR/$SID-worker-issue-close-finalize-$BIG.draft.json"
        printf '%s' '{"phase":"initial","issue_number":1}' > "$D_BIG"
        snap_draft "$D_BIG"
        node "$(np "$CLI")" --session "$SID" --worker issue-close-finalize --seq "$BIG" --draft "$(np "$D_BIG")" >/dev/null 2>&1 ; RC_BIG=$?
        seq_outcome "seq/max-boundary-$BIG" "$RC_BIG" "$D_BIG" "$CTRL/worker-issue-close-finalize-$BIG.json"
        STRAY="$(find "$CTRL" -name 'worker-issue-close-finalize-9007199254*.json' ! -name "worker-issue-close-finalize-$BIG.json" 2>/dev/null)"
        if [ -z "$STRAY" ]; then pass "seq/max-boundary-$BIG/no-rounded-name"
        else fail "seq/max-boundary-$BIG/no-rounded-name" "payload published under a rounded seq: $STRAY"; fi
        rm -f "$D_BIG" "$CTRL"/worker-issue-close-finalize-9007199254*.json 2>/dev/null
    else
        fail "seq/max-boundary-$BIG/exit-in-contract" "implementation missing: bin/worker-dispatch-payload absent"
    fi
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
