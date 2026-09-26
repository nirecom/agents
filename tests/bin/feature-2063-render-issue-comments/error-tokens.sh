#!/usr/bin/env bash
# tests/feature-2063-render-issue-comments/error-tokens.sh
# Tests: bin/workflow/render-issue-comments, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/write-context.js
# Tags: workflow-init, issue-comments, cli, contract, fail-closed, sentinel-strip, tl2, scope:common

# P4-P7, P10, P13, P22, P25 (#2063, fail-closed): every exit-3 reason token, the priority order between them, one stderr line, no stack, no leaked path.

# TL3 gap: the prompt layer actually invoking this bridge and omitting the prefill
# section on a non-zero rc is not observable here — only a real workflow-init run
# shows that. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# --- P4: current version, `comments` key absent = corruption, not legacy --------
# The CHECKPOINT_VERSION bump means a v2 checkpoint never reaches this code at all,
# so a missing key here can only be damage — and prefill must not be seeded from it.
nocomments_ckpt "$WORK/p4.json" 4004
run_cli --checkpoint "$WORK/p4.json" --issue 4004
assert_rc "P4: a missing comments key exits 3" 3
assert_err_has "P4: stderr names the comments_missing token" 'comments_missing'
assert_out_empty "P4: nothing is written to stdout on failure"
assert_no_stack "P4: no stack trace on stderr"

# --- P5/P6/P7: the upstream reason-tokens, in judgment order --------------------
run_cli --checkpoint "$WORK/does-not-exist.json" --issue 4005
assert_rc "P5: an absent checkpoint exits 3" 3
assert_err_has "P5: stderr names checkpoint_unreadable" 'checkpoint_unreadable'
assert_out_empty "P5: no stdout for an absent checkpoint"
assert_no_stack "P5: no stack trace on stderr"

raw_ckpt "$WORK/p6.json" '{"version":1,"session_id":"ric","state":{"issues":[4006],"issue_json_cache":{"4006":{"number":4006,"comments":[]}}}}'
run_cli --checkpoint "$WORK/p6.json" --issue 4006
assert_rc "P6: an old-version checkpoint exits 3" 3
assert_err_has "P6: stderr names version_mismatch (version gate stays in checkpoint.js)" 'version_mismatch'
assert_out_empty "P6: no stdout for a version mismatch"

healthy_ckpt "$WORK/p7.json" 4007 "$TWO_COMMENTS"
run_cli --checkpoint "$WORK/p7.json" --issue 9999
assert_rc "P7: an issue absent from the cache exits 3" 3
assert_err_has "P7: stderr names issue_not_cached" 'issue_not_cached'
assert_out_empty "P7: no stdout for an uncached issue"
# `null` is the refetch-pending marker; from the CLI's side that is the same
# "no usable data yet", so it must not become a different token.
raw_ckpt "$WORK/p7b.json" '{"version":3,"session_id":"ric","state":{"issues":[4007],"issue_json_cache":{"4007":null}}}'
run_cli --checkpoint "$WORK/p7b.json" --issue 4007
assert_rc "P7b: a null (refetch-pending) cache entry exits 3" 3
assert_err_has "P7b: a null cache entry is also issue_not_cached" 'issue_not_cached'
assert_out_empty "P7b: no stdout for a refetch-pending entry"


# --- P10 (array-level corruption): fail closed, one line, no trace -------------
check_p10() {  # <label> <comments-raw-json>
    healthy_ckpt "$WORK/p10.json" 4010 "$2"
    run_cli --checkpoint "$WORK/p10.json" --issue 4010
    assert_rc "P10/$1: exits 3" 3
    assert_out_empty "P10/$1: writes nothing to stdout"
    assert_err_only_line "P10/$1: stderr is exactly the one reason-token line" 'render-issue-comments: comments_not_array'
    assert_no_stack "P10/$1: no stack trace on stderr"
}
check_p10 string '"oops"'
check_p10 object '{}'
check_p10 number '42'
check_p10 null   'null'


# --- P13 (container-level corruption): readCheckpoint does not validate shape ---
# version 3 with a missing/!object `state` or `issue_json_cache` is reachable, and
# an unguarded `data.state.issue_json_cache[N]` turns it into a TypeError crash —
# which breaks the exit-3 contract and the empty-stdout contract at the same time.
check_p13() {  # <label> <raw-checkpoint-json> <want-token>
    raw_ckpt "$WORK/p13.json" "$2"
    run_cli --checkpoint "$WORK/p13.json" --issue 4013
    assert_rc "P13/$1: exits 3" 3
    assert_out_empty "P13/$1: writes nothing to stdout"
    assert_err_only_line "P13/$1: stderr is exactly the one reason-token line" "render-issue-comments: $3"
    assert_no_stack "P13/$1: no TypeError or stack frame on stderr"
}
check_p13 "state absent" '{"version":3,"session_id":"ric","phase":"write-context"}' checkpoint_state_missing
check_p13 "state null"   '{"version":3,"session_id":"ric","state":null}'            checkpoint_state_missing
check_p13 "state array"  '{"version":3,"session_id":"ric","state":[]}'              checkpoint_state_missing
check_p13 "cache absent" '{"version":3,"session_id":"ric","state":{"issues":[4013]}}' issue_cache_missing
check_p13 "cache null"   '{"version":3,"session_id":"ric","state":{"issue_json_cache":null}}' issue_cache_missing
# `typeof [] === "object"`, so a naive typeof guard lets an array through and the
# numeric-index lookup can accidentally hit.
check_p13 "cache array"  '{"version":3,"session_id":"ric","state":{"issue_json_cache":[]}}' issue_cache_missing


# --- P22 (C6): every reason-token, exactly, and the priority order between them --
# The promise is one line on stderr and nothing else — no second diagnostic, no host
# path, no stack frame. `assert_err_only_line` is the exact form; `assert_no_leak`
# (./_lib.sh, shared with P8) is separate because a path can be leaked inside a
# single well-formed line just as easily.
check_token() {  # <label> <ckpt-path> <issue-arg> <want-token>
    run_cli --checkpoint "$2" --issue "$3"
    assert_rc "P22/$1: exits 3" 3
    assert_out_empty "P22/$1: stdout stays empty"
    assert_err_only_line "P22/$1: stderr is exactly one reason-token line" "render-issue-comments: $4"
    assert_no_stack "P22/$1: no stack frame on stderr"
    assert_no_leak "P22/$1: the checkpoint path is not echoed back" "$WORK"
}
mkdir -p "$WORK/p22-dir.json"
: > "$WORK/p22-empty.json"
raw_ckpt "$WORK/p22-malformed.json" '{"version":3,"state":{'
raw_ckpt "$WORK/p22-notjson.json"   'this is not json at all'
raw_ckpt "$WORK/p22-v1.json"        '{"version":1,"state":{"issue_json_cache":{"4024":{"comments":[]}}}}'
raw_ckpt "$WORK/p22-nostate.json"   '{"version":3,"session_id":"ric"}'
raw_ckpt "$WORK/p22-nocache.json"   '{"version":3,"session_id":"ric","state":{"issues":[4024]}}'
healthy_ckpt "$WORK/p22-ok.json" 4024 "$TWO_COMMENTS"
nocomments_ckpt "$WORK/p22-nokey.json" 4024
raw_ckpt "$WORK/p22-notarr.json"    '{"version":3,"session_id":"ric","state":{"issue_json_cache":{"4024":{"number":4024,"comments":"oops"}}}}'
check_token "absent file"        "$WORK/does-not-exist.json"   4024 checkpoint_unreadable
check_token "directory"          "$WORK/p22-dir.json"          4024 checkpoint_unreadable
check_token "empty file"         "$WORK/p22-empty.json"        4024 checkpoint_unreadable
check_token "truncated json"     "$WORK/p22-malformed.json"    4024 checkpoint_unreadable
check_token "not json at all"    "$WORK/p22-notjson.json"      4024 checkpoint_unreadable
check_token "old version"        "$WORK/p22-v1.json"           4024 version_mismatch
# The IMMEDIATE predecessor, and the one that actually exists in the wild: a complete,
# well-formed VERSION-2 checkpoint written by the pre-#2063 driver — every field of
# makeInitialState() present, the cache entry fully populated, and no `comments` key
# because that schema had none. `version:1` cannot stand in for it: a v1 fixture is
# rejected by any gate at all, while this one is rejected only by a gate that compares
# against the CURRENT version rather than "older than 2" or "looks structurally sound".
# Its cache entry is healthy, so a CLI that skipped the version gate would answer
# comments_missing here — a plausible-looking token for a file that must never be read.
raw_ckpt "$WORK/p22-v2.json" '{"version":2,"session_id":"ric","phase":"write-context","ask_id":null,"state":{"issues":[4024],"issue_json_cache":{"4024":{"number":4024,"title":"Fixture issue","body":"Fixture body","labels":[],"state":"OPEN","createdAt":"2026-07-01T00:00:00Z"}},"labels":{},"meta_issues":[],"closed_issues":[],"wip_state":null,"path_decision":null}}'
check_token "version 2 (predecessor)" "$WORK/p22-v2.json"      4024 version_mismatch
# The other side of the same gate (CPR-ORTH): a checkpoint from a FUTURE bump is equally
# unreadable. A `data.version < 3` comparison passes it through; only equality rejects it.
raw_ckpt "$WORK/p22-v4.json" '{"version":4,"session_id":"ric","state":{"issue_json_cache":{"4024":{"number":4024,"comments":[]}}}}'
check_token "newer version"      "$WORK/p22-v4.json"           4024 version_mismatch
check_token "state missing"      "$WORK/p22-nostate.json"      4024 checkpoint_state_missing
check_token "cache missing"      "$WORK/p22-nocache.json"      4024 issue_cache_missing
check_token "issue not cached"   "$WORK/p22-ok.json"           8888 issue_not_cached
check_token "comments key gone"  "$WORK/p22-nokey.json"        4024 comments_missing
check_token "comments not array" "$WORK/p22-notarr.json"       4024 comments_not_array
# Compound defects: each fixture carries the defect named AND every defect below it in
# the table, so a renumbered or reordered guard chain changes the token that surfaces.
raw_ckpt "$WORK/p22-c1.json" '{"version":1}'
check_token "v1 AND no state"          "$WORK/p22-c1.json" 4024 version_mismatch
raw_ckpt "$WORK/p22-c2.json" '{"version":3,"state":null}'
check_token "no state AND no cache"    "$WORK/p22-c2.json" 4024 checkpoint_state_missing
raw_ckpt "$WORK/p22-c3.json" '{"version":3,"state":[]}'
check_token "array state outranks all" "$WORK/p22-c3.json" 4024 checkpoint_state_missing
raw_ckpt "$WORK/p22-c4.json" '{"version":3,"state":{"issue_json_cache":[]}}'
check_token "array cache AND uncached" "$WORK/p22-c4.json" 4024 issue_cache_missing
raw_ckpt "$WORK/p22-c5.json" '{"version":3,"state":{"issue_json_cache":{"9999":{"number":9999}}}}'
check_token "uncached outranks broken sibling" "$WORK/p22-c5.json" 4024 issue_not_cached
raw_ckpt "$WORK/p22-c6.json" '{"version":3,"state":{"issue_json_cache":{"4024":null,"9999":{"comments":"oops"}}}}'
check_token "null entry outranks a broken sibling" "$WORK/p22-c6.json" 4024 issue_not_cached
# A syntactically broken file whose version *text* is old must still be unreadable:
# the parse comes before the version gate, so this is the ordering of 1 over 2.
raw_ckpt "$WORK/p22-c7.json" '{"version":1,'
check_token "unparseable outranks version" "$WORK/p22-c7.json" 4024 checkpoint_unreadable


# --- P25 (C6): a checkpoint the process may not READ -----------------------------
# Distinct from absent and from a directory: the file exists and its shape is fine, but
# open() fails with EACCES. A reader that treats "exists" as "readable" reports the wrong
# token here, and one that lets the exception escape prints a stack instead of a line.
# Running as root/Administrator defeats mode 000, so the fixture is verified genuinely
# unreadable before the case is claimed — an unverifiable host is skipped, not faked.
P25_CKPT="$WORK/p25-noperm.json"
healthy_ckpt "$P25_CKPT" 4031 "$TWO_COMMENTS"
chmod 000 "$P25_CKPT" 2>/dev/null || true
P25_READABLE="$(node -e '
const fs = require("fs");
try { fs.readFileSync(process.argv[1], "utf8"); process.stdout.write("READABLE"); }
catch (e) { process.stdout.write("DENIED:" + (e.code || "?")); }
' "$P25_CKPT" 2>/dev/null || printf 'READABLE:probe-failed')"
case "$P25_READABLE" in
    DENIED:*)
        check_token "permission denied" "$P25_CKPT" 4031 checkpoint_unreadable ;;
    *)
        echo "SKIP: P25/permission-denied: Skipped-Because: this host still reads a mode-000 file ($P25_READABLE) — the process runs as root/Administrator or the filesystem ignores POSIX modes, so a genuine EACCES cannot be staged here; on such a host the checkpoint_unreadable token is exercised only by the absent-file and directory cases in P22" ;;
esac
chmod 644 "$P25_CKPT" 2>/dev/null || true

# --- P27: JSON that PARSES but is not a checkpoint --------------------------------
# P22/P13 corrupt the file (unparseable) or a nested container (`state`, the cache).
# The untested band between them is a document that parses perfectly and is simply the
# wrong KIND of value — the shape a truncated writer, an empty-array initialiser or a
# `null` placeholder leaves behind. Every one reaches the same unguarded
# `data.version` / `entry.comments` dereference, so each must still be one exit-3 line.
check_p27() {  # <label> <raw-checkpoint-json> <issue-arg> <want-token>
    raw_ckpt "$WORK/p27.json" "$2"
    run_cli --checkpoint "$WORK/p27.json" --issue "$3"
    assert_rc "P27/$1: exits 3" 3
    assert_out_empty "P27/$1: writes nothing to stdout"
    assert_err_only_line "P27/$1: stderr is exactly the one reason-token line" "render-issue-comments: $4"
    assert_no_stack "P27/$1: no TypeError or stack frame on stderr"
    assert_no_leak "P27/$1: the checkpoint path is not echoed back" "$WORK"
}
# (a) The TOP-LEVEL value is not an object. A scalar and an array both carry no
# `version`, so the version gate — which runs before any state lookup — owns them.
check_p27 "top-level number" '42'         4040 version_mismatch
check_p27 "top-level string" '"oops"'     4040 version_mismatch
check_p27 "top-level true"   'true'       4040 version_mismatch
check_p27 "top-level array"  '[]'         4040 version_mismatch
check_p27 "top-level array of entries" '[{"version":3}]' 4040 version_mismatch
# `null` differs from every shape above: the scalars and arrays carry a `version`
# property that reads `undefined`, so the version gate owns them, while `null` cannot
# be dereferenced at all. That makes it the file that PARSED yet yielded no checkpoint —
# exactly what token 1 aggregates (`not_found` / `unreadable` / `malformed` are all
# "no checkpoint came back"), so the CLI must reach it through a guard of its own
# rather than letting the dereference escape.
check_p27 "top-level null" 'null' 4040 checkpoint_unreadable
# Pinned separately because it is the whole point of a 7-token contract: internal_error
# is main()'s catch-all for the UNFORESEEN, and a CLI with no shape guard at all — one
# whose `data.version` dereference simply throws — lands there. Accepting it would make
# the case above green for an implementation that never handled this shape.
case "$CLI_ERR" in
    *internal_error*)
        fail "P27/top-level null: the internal_error catch-all surfaced — the first-line guard for a null checkpoint is missing" ;;
    *)
        pass "P27/top-level null: a first-line reason token answers this shape, not the internal_error catch-all" ;;
esac
# (b) The CACHE ENTRY for the requested issue is not an object. `entry.comments` on a
# primitive is `undefined` rather than a throw, so these fall through the container
# guards and land on the comments guard — comments_missing, not a crash and not
# comments_not_array (nothing was read to have the wrong type).
check_p27 "entry number"        '{"version":3,"state":{"issue_json_cache":{"4040":42}}}'        4040 comments_missing
check_p27 "entry string"        '{"version":3,"state":{"issue_json_cache":{"4040":"oops"}}}'    4040 comments_missing
check_p27 "entry true"          '{"version":3,"state":{"issue_json_cache":{"4040":true}}}'      4040 comments_missing
check_p27 "entry empty array"   '{"version":3,"state":{"issue_json_cache":{"4040":[]}}}'        4040 comments_missing
check_p27 "entry array of one"  '{"version":3,"state":{"issue_json_cache":{"4040":["x"]}}}'     4040 comments_missing
# A FALSY primitive entry is a different class: like the `null` refetch-pending marker
# (P7b), there is no usable issue data at all, so it keeps that marker's token rather
# than claiming the comments key specifically went missing.
check_p27 "entry zero"          '{"version":3,"state":{"issue_json_cache":{"4040":0}}}'         4040 issue_not_cached
check_p27 "entry empty string"  '{"version":3,"state":{"issue_json_cache":{"4040":""}}}'        4040 issue_not_cached
check_p27 "entry false"         '{"version":3,"state":{"issue_json_cache":{"4040":false}}}'     4040 issue_not_cached


# --- P29 (C8): the internal_error catch-all, driven by a REAL failure --------------
# Every case above asserts where internal_error must NOT appear. Nothing yet reaches it,
# so `catch { … internal_error … }` could be dead code — or could print a stack — and the
# suite would stay green. The trigger has to be a failure none of the 7 guards can own:
# after they pass, the only I/O left is the write to stdout itself, so the case runs the
# CLI with FILE DESCRIPTOR 1 CLOSED. Reaching `process.stdout` then fails inside main(),
# which is precisely the unforeseen-exception band the catch-all exists for.
# stdout is closed, so run_cli's `$(...)` capture cannot be used here — the process is
# invoked directly and only stderr is collected.
P29_CKPT="$WORK/p29.json"
healthy_ckpt "$P29_CKPT" 4050 "$TWO_COMMENTS"
# Liveness first: the same checkpoint and the same argv render normally. Without this,
# every assertion below would also be satisfied by a CLI that fails on this fixture for
# an ordinary reason, and the case would prove nothing about the catch-all.
run_cli --checkpoint "$P29_CKPT" --issue 4050
assert_rc "P29/liveness: the fixture renders normally when stdout is open" 0
assert_out_has "P29/liveness: the rendered output is the real thing" '> first remark'
# Whether a closed fd 1 actually fails is a host property (node may substitute a dummy
# stream), so it is probed rather than assumed — same discipline as P25.
P29_PROBE_RC=0
node -e 'process.stdout.write("probe\n")' >&- 2>/dev/null || P29_PROBE_RC=$?
if [ ! -f "$CLI" ]; then
    fail "P29: the CLI does not exist — the internal_error catch-all is not observable"
elif [ "$P29_PROBE_RC" = "0" ]; then
    echo "SKIP: P29/internal-error: Skipped-Because: node on this host still succeeds writing to a closed fd 1 (probe rc=0), so no post-guard failure can be staged without patching the CLI's own dependencies — which would assert against a fixture rather than the shipped code; the internal_error token stays covered only negatively (P27 asserts it must not surface for a guarded shape)"
else
    P29_RC=0
    "$TIMEOUT_WRAP" 30 node "$CLI" --checkpoint "$P29_CKPT" --issue 4050 >&- 2>"$WORK/p29-err" || P29_RC=$?
    CLI_ERR="$(cat "$WORK/p29-err" 2>/dev/null || true)"
    CLI_RC="$P29_RC"
    assert_rc "P29: an unforeseen failure after the guards still exits 3" 3
    assert_err_only_line "P29: stderr is exactly the internal_error line" 'render-issue-comments: internal_error'
    assert_no_stack "P29: the catch-all prints no stack frame"
    assert_no_leak "P29: the checkpoint path is not echoed back" "$WORK"
    # The token must be the catch-all, not a guard token borrowed to look tidy: the
    # checkpoint is provably healthy (the liveness run above rendered from it), so any
    # of the 7 reason tokens here would be a lie about the file.
    case "$CLI_ERR" in
        *unreadable*|*version_mismatch*|*state_missing*|*cache_missing*|*not_cached*|*comments_*)
            fail "P29: a guard token was reported for a healthy checkpoint: '$(printf '%s' "$CLI_ERR" | head -c 200)'" ;;
        *)
            pass "P29: the failure is not misreported as one of the seven guard tokens" ;;
    esac
fi

finish
