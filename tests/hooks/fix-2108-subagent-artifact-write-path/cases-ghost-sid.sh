#!/usr/bin/env bash
# Tests: hooks/lib/active-session-ids.js, hooks/lib/worktree-notes-session-ids.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js
# Tags: active-session-ids, worktree-notes, protected-basename, memoization, fail-closed, end-to-end, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Sections C12 + C13 — the GHOST-SID hole and its closure.
# THE HOLE: observeActiveSessionIds() asks resolveSessionId(), which returns at
# priority 1 on any stdin session_id and therefore NEVER reads the agent-writable
# `Session-ID:` line in WORKTREE_NOTES.md. A clearance READER in another process has
# no stdin sid, falls through to priority 6/6b/6c, and DOES honour that line. So an
# agent plants its own sid there, writes `<that-stem>.<kind>` past a classifier that
# cannot see it, and the reader later opens the file as genuine state.
GS_CFG=""

# C12 covers the observation module: the union, the two same-file memo/charset defects,
# and fault propagation. C13 drives the whole thing through the REAL hook subprocess —
# the only place the premise "the write actually lands" is observed rather than assumed.
GS_WF=""
GS_TGT=""
GS_TGT_FWD=""
GS_TGT_SH=""
GS_NOTES=""
GS_NOTES_MIXED=""
GS_CLEAN=""
GS_PRELOAD_NODE=""

# The known body seeded into a protected file before a forged write is attempted
# (C13-7). Distinctive on purpose: the negative assertion compares the whole content.
GS_GENUINE="GENUINE-MARKER-BODY-2108"

_gs_write_probes() {
    cat > "$PROBE_DIR/gs-observe-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <active-session-ids.js> <ctx-json> -> "<complete>|<sids, sorted, comma-joined>"
const m = require(process.argv[2]);
let ctx = {};
try { ctx = JSON.parse(process.argv[3] || "{}"); } catch (_) {}
const r = m.observeActiveSessionIds(ctx);
process.stdout.write(String(r.complete) + "|" + Array.from(r.sids).sort().join(","));
PROBE_EOF
    cat > "$PROBE_DIR/gs-memo-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <module> <ctxA-json> <ctxB-json> [cwdA] [cwdB] -> "<sidsA>||<sidsB>"
// TWO calls in ONE process, so the module-level memo is live for the second. If the
// memo key omits a field that changed between them, B silently returns A's answer.
const m = require(process.argv[2]);
const snap = (raw, dir) => {
  if (dir) process.chdir(dir);
  return Array.from(m.observeActiveSessionIds(JSON.parse(raw)).sids).sort().join(",");
};
const a = snap(process.argv[3], process.argv[5]);
const b = snap(process.argv[4], process.argv[6]);
process.stdout.write(a + "||" + b);
PROBE_EOF
    cat > "$PROBE_DIR/gs-stem-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <protected-basenames.js> <stem> <spelling> <sid|-> -> isClearanceBearingStem
const p = require(process.argv[2]);
const opts = { spelling: process.argv[4] };
if (process.argv[5] && process.argv[5] !== "-") opts.sessionCtx = { sessionId: process.argv[5] };
process.stdout.write(String(p.isClearanceBearingStem(process.argv[3], opts)));
PROBE_EOF
    cat > "$PROBE_DIR/gs-notes-fault-preload.js" <<'PROBE_EOF'
"use strict";
// `node -r THIS`: swaps enumerateWorktreeNotesSessionIds() in the require cache BEFORE
// active-session-ids.js destructures it, so the injected fault IS the dependency —
// the only way to reach it, since the real module catches everything internally.
// env: GS_NOTES_MODULE (absolute path to the module), GS_NOTES_FAULT_MODE.
const p = require.resolve(process.env.GS_NOTES_MODULE);
require(p);
const faults = {
  throws: () => { throw new Error("notes enumeration exploded"); },
  nullret: () => null,
  strsids: () => ({ sids: "not-an-array", complete: true }),
  incomplete: () => ({ sids: [], complete: false }),
};
const f = faults[process.env.GS_NOTES_FAULT_MODE || ""];
if (f) {
  require.cache[p].exports = Object.assign({}, require.cache[p].exports, {
    enumerateWorktreeNotesSessionIds: f,
  });
}
PROBE_EOF
    cat > "$PROBE_DIR/gs-fault-observe-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <active-session-ids.js> <ctx-json> -> "<complete>|<sids>", or "THREW".
// The catch is the POINT: it separates "the fault reached the caller" from "the fault
// was absorbed into a narrowed complete:true set", which is the fail-open shape.
const m = require(process.argv[2]);
try {
  const r = m.observeActiveSessionIds(JSON.parse(process.argv[3] || "{}"));
  process.stdout.write(String(r.complete) + "|" + Array.from(r.sids).sort().join(","));
} catch (_) { process.stdout.write("THREW"); }
PROBE_EOF
}

# _gs_in <cwd> <probe-args...> — probe under the section's pinned workflow dir
_gs_in() {
    local dir="$1"; shift
    (
        cd "$dir" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export CLAUDE_WORKFLOW_DIR="$GS_WF"
        export WORKFLOW_PLANS_DIR="$GS_WF"
        run_probe "$@"
    )
}

# _gs_hook <cwd> <stdin-json> -> raw block-clearance-token-write stdout
_gs_hook() {
    local dir="$1" input="$2"
    (
        cd "$dir" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export AGENTS_CONFIG_DIR="$GS_CFG"
        export CLAUDE_WORKFLOW_DIR="$GS_WF"
        export WORKFLOW_PLANS_DIR="$GS_WF"
        run_hook_capture "$input" "$RWT" 20 node "$BCTW_HOOK"
    )
}

# _gs_in_faulty / _gs_hook_faulty — the same two runners with the notes-enumeration
# dependency replaced by <mode> (C12-4b). `none` selects no fault and is the harness
# control: it must reproduce the ordinary answer, or the fault rows prove nothing.
_gs_in_faulty() {
    local dir="$1" mode="$2"; shift 2
    (
        cd "$dir" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export CLAUDE_WORKFLOW_DIR="$GS_WF"
        export WORKFLOW_PLANS_DIR="$GS_WF"
        export GS_NOTES_MODULE="$WT_NOTES_NODE"
        export GS_NOTES_FAULT_MODE="$mode"
        run_probe -r "$PROBE_DIR/gs-notes-fault-preload.js" "$@"
    )
}

_gs_hook_faulty() {
    local dir="$1" mode="$2" input="$3"
    (
        cd "$dir" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export AGENTS_CONFIG_DIR="$GS_CFG"
        export CLAUDE_WORKFLOW_DIR="$GS_WF"
        export WORKFLOW_PLANS_DIR="$GS_WF"
        export GS_NOTES_MODULE="$WT_NOTES_NODE"
        export GS_NOTES_FAULT_MODE="$mode"
        # NATIVE preload path: run_hook_capture sets MSYS_NO_PATHCONV=1, so a /tmp/...
        # spelling would reach node unrewritten and fail to resolve.
        run_hook_capture "$input" "$RWT" 20 node -r "$GS_PRELOAD_NODE" "$BCTW_HOOK"
    )
}

# --- Pattern 1 harness (protection-fix-tests.md) -----------------------------------
# The hook is a PreToolUse gate: the TOOL runs only when it does not block. These two
# helpers reproduce that contract — decision on stdout, and the write/delete actually
# PERFORMED on approve — so a negative row can assert the file on disk rather than the
# verdict string. Used by C13-7.
_gs_read() { if [ -e "$1" ]; then cat "$1"; else printf '<absent>'; fi; }

# _gs_gated_write <cwd> <sid> <target-fwd> <target-sh> <content> -> decision
_gs_gated_write() {
    local dir="$1" sid="$2" fwd="$3" shp="$4" content="$5" d
    d="$(gate_decision "$(_gs_hook "$dir" "$(mk_edit_input Write "$sid" "$fwd")")")"
    [ "$d" = "approve" ] && printf '%s' "$content" > "$shp"
    printf '%s' "$d"
}

# _gs_gated_bash <cwd> <command> -> decision; on approve the command REALLY runs.
_gs_gated_bash() {
    local dir="$1" cmd="$2" d
    d="$(gate_decision "$(_gs_hook "$dir" "$(_c5_cmd "$cmd")")")"
    [ "$d" = "approve" ] && bash -c "$cmd" >/dev/null 2>&1
    printf '%s' "$d"
}

_gs_setup() {
    local base="$TMPBASE_SH/ghost-sid"
    rm -rf "$base" 2>/dev/null || true
    mkdir -p "$base/config" "$base/wf" "$base/target" "$base/notes" "$base/notes-mixed" "$base/clean"
    GS_CFG="$(node_path "$base/config")"
    GS_WF="$(node_path "$base/wf")"
    GS_TGT="$(node_path "$base/target")"
    GS_TGT_FWD="${GS_TGT//\\//}"
    GS_TGT_SH="$base/target"
    GS_NOTES="$base/notes"
    GS_NOTES_MIXED="$base/notes-mixed"
    GS_CLEAN="$base/clean"
    GS_PRELOAD_NODE="$(node_path "$PROBE_DIR")/gs-notes-fault-preload.js"
    printf '{"version":1,"session_id":"wsid"}' > "$base/wf/wsid.json"
    printf 'Session-ID: ghost-planted-sid\n' > "$GS_NOTES/WORKTREE_NOTES.md"
    # Same id, agent-chosen CASING — the fixture C13-8 targets in lower case.
    printf 'Session-ID: Ghost-Planted-Sid\n' > "$GS_NOTES_MIXED/WORKTREE_NOTES.md"
    rm -f "$GS_CLEAN/WORKTREE_NOTES.md" 2>/dev/null || true
    _gs_write_probes
}

run_C12_ghost_observation() {
    local base memo_a memo_b out wf_file

    _gs_setup
    base="$TMPBASE_SH/ghost-sid"

    # C12-1 — THE UNION. `wsid` arrives on stdin and short-circuits resolveSessionId,
    # so the planted value is invisible to the resolver; the observation must collect
    # it anyway, because a reader without a stdin sid will resolve to exactly it.
    assert_eq "C12-1 planted WORKTREE_NOTES sid joins the observed set" \
        "true|ghost-planted-sid,wsid" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"

    # C12-1b — the control that makes C12-1 a discriminator rather than a tautology:
    # the identical call from a directory with NO notes file yields only `wsid`.
    assert_eq "C12-1b control: no notes file -> only the stdin sid is observed" "true|wsid" \
        "$(_gs_in "$GS_CLEAN" "$PROBE_DIR/gs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"

    # C12-1c — and the state store is still enumerated alongside the notes value, so
    # the union is a union and not a replacement.
    printf '{"version":1,"session_id":"storesid"}' > "$base/wf/storesid.json"
    assert_eq "C12-1c store entries and notes value are both present" \
        "true|ghost-planted-sid,storesid,wsid" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    rm -f "$base/wf/storesid.json" 2>/dev/null || true

    # C12-2 — MEMO KEY vs transcriptPath. `bad.sid` is outside the sid alphabet, so
    # resolveSessionId skips it and answers from the transcript basename instead. Two
    # calls share the current memo key (`fromInput || ""`) while differing in the field
    # that actually decided the answer, so the second call returns the first's set.
    memo_a="$(_gs_in "$GS_CLEAN" "$PROBE_DIR/gs-memo-probe.js" "$ACTIVE_SIDS_NODE" \
        '{"sessionId":"bad.sid","transcriptPath":"/xx/tsidaaaa.jsonl"}' \
        '{"sessionId":"bad.sid","transcriptPath":"/xx/tsidbbbb.jsonl"}')"
    # `wsid` appears in both halves because it is a real entry in the pinned state
    # store; the transcript-derived id is the only field that differs.
    assert_eq "C12-2 memo key must include transcriptPath" "tsidaaaa,wsid||tsidbbbb,wsid" "$memo_a"

    # C12-2b — the same fixture proves the charset gate on `fromInput`: a value that is
    # not a legal state-file stem must never be added to the set, or an agent could
    # name its own clearance stem simply by sending it on stdin.
    assert_not_contains "C12-2b out-of-alphabet stdin sid never enters the observed set" \
        "bad.sid" "$memo_a"
    assert_eq "C12-2b control: an in-alphabet stdin sid IS added" "true|good-sid,wsid" \
        "$(_gs_in "$GS_CLEAN" "$PROBE_DIR/gs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"good-sid"}')"

    # C12-3 — MEMO KEY vs the working directory. Same stdin sid, two directories with
    # different planted values: once the notes files feed the set, cwd is part of the
    # answer and must therefore be part of the key.
    mkdir -p "$base/cwd-a" "$base/cwd-b"
    printf 'Session-ID: cwd-a-sid\n' > "$base/cwd-a/WORKTREE_NOTES.md"
    printf 'Session-ID: cwd-b-sid\n' > "$base/cwd-b/WORKTREE_NOTES.md"
    memo_b="$(_gs_in "$GS_CLEAN" "$PROBE_DIR/gs-memo-probe.js" "$ACTIVE_SIDS_NODE" \
        '{"sessionId":"wsid"}' '{"sessionId":"wsid"}' \
        "$(node_path "$base/cwd-a")" "$(node_path "$base/cwd-b")")"
    assert_eq "C12-3 memo key must include process.cwd()" \
        "cwd-a-sid,wsid||cwd-b-sid,wsid" "$memo_b"

    # C12-4 — FAULT PROPAGATION, asserted from INSIDE the poisoned directory. The
    # workflow dir is a FILE, so readdirSync throws ENOTDIR on every platform. A
    # readable notes file next to an unreadable store must NOT let the observation
    # report itself complete: partial knowledge is exactly the state in which no
    # narrowing may be applied, and the pre-#2108 suffix-only breadth returns.
    printf 'not a directory' > "$base/wf-file"
    wf_file="$(node_path "$base/wf-file")"
    out="$(cd "$GS_NOTES" && CLAUDE_WORKFLOW_DIR="$wf_file" WORKFLOW_PLANS_DIR="$wf_file" run_probe "$PROBE_DIR/gs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_contains "C12-4 a store fault reports complete:false even with notes present" "false|" "$out"
    assert_eq "C12-4 complete:false makes every stem clearance-bearing (clean)" "true" \
        "$(cd "$GS_NOTES" && CLAUDE_WORKFLOW_DIR="$wf_file" WORKFLOW_PLANS_DIR="$wf_file" run_probe "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "issue-2108-survey" clean wsid)"

    # C12-4b — the fault one layer BELOW C12-4: not the state store, but the
    # notes-enumeration DEPENDENCY itself, swapped in the require cache (`node -r`)
    # because the real module catches everything internally (C10-1b, C11-1/C11-2).
    # CONTROL first: preload loaded, no fault selected -> the C12-1 answer unchanged.
    assert_eq "C12-4b harness control: the preload alone changes nothing" \
        "true|ghost-planted-sid,wsid" \
        "$(_gs_in_faulty "$GS_NOTES" none "$PROBE_DIR/gs-fault-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"

    # (i) the dependency reports its OWN documented fault. It must reach the caller's
    # `complete`: a set narrowed on a half-read view is the fail-OPEN this module
    # exists to prevent, so the narrowing has to switch off instead.
    assert_eq "C12-4b a notes-side complete:false propagates to the observation" "false|wsid" \
        "$(_gs_in_faulty "$GS_NOTES" incomplete "$PROBE_DIR/gs-fault-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_eq "C12-4b ... so the classifier blocks even an artifact stem (Write)" "block" \
        "$(gate_decision "$(_gs_hook_faulty "$GS_NOTES" incomplete "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/issue-2108-survey.gh-env")")")"
    assert_eq "C12-4b ... and on the bash route too (CPR-ORTH)" "block" \
        "$(gate_decision "$(_gs_hook_faulty "$GS_NOTES" incomplete "$(_c5_cmd "echo x > $GS_TGT_FWD/issue-2108-survey.gh-env")")")"

    # (ii) a MALFORMED return the code silently survives: `sids` a string, iterated
    # character by character into the observed set. Pollution must never narrow a REAL
    # session's marker out of protection, nor widen the gate onto an artifact.
    assert_eq "C12-4b a malformed sids value never un-protects a live session marker" "block" \
        "$(gate_decision "$(_gs_hook_faulty "$GS_NOTES" strsids "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/wsid.workflow-off")")")"
    assert_eq "C12-4b ... and does not over-block an unrelated artifact either" "approve" \
        "$(gate_decision "$(_gs_hook_faulty "$GS_NOTES" strsids "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/issue-2108-survey.gh-env")")")"

    # (iii) a dependency that THROWS, and one that answers null. The one outcome that
    # would silently allow a forgery is absorption into a complete:true narrowed set;
    # the fault must reach the caller, which on the Bash route resolves to a block.
    assert_eq "C12-4b a throwing dependency is never absorbed into a complete observation" "THREW" \
        "$(_gs_in_faulty "$GS_NOTES" throws "$PROBE_DIR/gs-fault-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_eq "C12-4b a null-returning dependency likewise" "THREW" \
        "$(_gs_in_faulty "$GS_NOTES" nullret "$PROBE_DIR/gs-fault-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_eq "C12-4b the bash route still blocks a live session's token when it throws" "block" \
        "$(gate_decision "$(_gs_hook_faulty "$GS_NOTES" throws "$(_c5_cmd "echo x > $GS_TGT_FWD/wsid.off-clearance")")")"
    # SKIPPED: the same block on the Edit/Write route while the dependency throws.
    # Because: block-clearance-token-write.js is fail-OPEN by contract, so a throw
    # there returns `approve` for a live marker (observed, not assumed) — unreachable
    # in production only because the real enumeration never throws (C10-1b/C11-1/2).
    # L3 gap: an edit that lets it throw re-opens the Edit/Write route silently while
    # the Bash route keeps blocking.

    # C12-5 — the predicate itself, which is what both write guards consult. TRUE on
    # BOTH spellings: `clean` matches the stem exactly, `bash` matches it as a tail.
    assert_eq "C12-5 isClearanceBearingStem(ghost-planted-sid, clean) is true" "true" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "ghost-planted-sid" clean wsid)"
    assert_eq "C12-5 isClearanceBearingStem(ghost-planted-sid, bash) is true" "true" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "ghost-planted-sid" bash wsid)"
    assert_eq "C12-5 bash spelling also catches it as a TAIL (report-<planted>)" "true" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "report-ghost-planted-sid" bash wsid)"

    # C12-5b — CPR-UNV counterweight: the narrowing must survive. From the SAME notes
    # directory an unrelated artifact stem is still not clearance-bearing, on either
    # spelling — otherwise C12-5 would pass on a predicate that answers true always.
    assert_eq "C12-5b control: artifact stem is still not clearance-bearing (clean)" "false" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "issue-2108-survey" clean wsid)"
    assert_eq "C12-5b control: artifact stem is still not clearance-bearing (bash)" "false" \
        "$(_gs_in "$GS_NOTES" "$PROBE_DIR/gs-stem-probe.js" "$PB_NODE" "issue-2108-survey" bash wsid)"
}

# Section C13 — the same attack driven end-to-end through the real hook subprocess.
# C12 asserts the predicate; only this section observes the VERDICT an agent would
# actually receive, across both tool routes, both suffix families and both directions.
run_C13_ghost_end_to_end() {
    local out

    _gs_setup

    if [ -f "$BCTW_HOOK" ]; then
        pass "C13-0 block-clearance-token-write.js present"
    else
        fail "C13-0 block-clearance-token-write.js MISSING at $BCTW_HOOK - Section C13 would be vacuous"
        return
    fi

    # C13-1 — the Write route. The stem is not sid-SHAPED and is not in the state store;
    # the ONLY thing making it clearance-bearing is the planted WORKTREE_NOTES line.
    out="$(_gs_hook "$GS_NOTES" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/ghost-planted-sid.workflow-off")")"
    assert_eq "C13-1 Write of a ghost-sid MARKER is blocked" "block" "$(gate_decision "$out")"
    assert_contains "C13-1 the block explains itself" "blocked" "$(gate_reason "$out")"

    # C13-1b — the discriminator. Identical payload, a cwd with no notes file: allowed.
    # Without this row C13-1 could be satisfied by a guard that blocks the suffix alone,
    # i.e. by reinstating the very false positive #2108 reports.
    assert_eq "C13-1b control: same payload, no planted notes -> allowed" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_CLEAN" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/ghost-planted-sid.workflow-off")")")"

    # C13-2 — CPR-ORTH over the SUFFIX FAMILIES: the 18 marker suffixes and the 7
    # clearance-token suffixes are two independent lists, and the stem rule gates both.
    assert_eq "C13-2 Write of a ghost-sid TOKEN is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/ghost-planted-sid.off-clearance")")")"
    assert_eq "C13-2 control: the token suffix is allowed without the planted notes" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_CLEAN" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/ghost-planted-sid.off-clearance")")")"

    # C13-2b — CPR-ORTH over the EDIT TOOLS: Edit and MultiEdit reach the same branch
    # and would otherwise be an untested way in.
    assert_eq "C13-2b Edit of a ghost-sid marker is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(mk_edit_input Edit "wsid" "$GS_TGT_FWD/ghost-planted-sid.workflow-off")")")"
    assert_eq "C13-2b MultiEdit of a ghost-sid marker is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(mk_edit_input MultiEdit "wsid" "$GS_TGT_FWD/ghost-planted-sid.workflow-off")")")"

    # C13-3 — the Bash route (dispatch.js sends command tools to bashHitsProtected(),
    # a different code path from the Write branch above).
    assert_eq "C13-3 bash redirect onto a ghost-sid marker is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "echo x > $GS_TGT_FWD/ghost-planted-sid.gh-env")")")"
    assert_eq "C13-3 bash redirect onto a ghost-sid token is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "echo x > $GS_TGT_FWD/ghost-planted-sid.off-clearance")")")"
    assert_eq "C13-3 control: the same redirect is allowed without the planted notes" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_CLEAN" "$(_c5_cmd "echo x > $GS_TGT_FWD/ghost-planted-sid.gh-env")")")"

    # C13-4 — the DELETE direction. Planting a marker forges clearance; removing one
    # revokes it. Both are writes to the same reader-visible state, so the stem rule
    # must gate `rm` exactly as it gates the redirect (CPR-ORTH, CPR-E2E).
    assert_eq "C13-4 rm of a ghost-sid marker is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "rm -f $GS_TGT_FWD/ghost-planted-sid.workflow-off")")")"
    assert_eq "C13-4 rm of a ghost-sid token is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "rm -f $GS_TGT_FWD/ghost-planted-sid.off-clearance")")")"
    assert_eq "C13-4 control: the same rm is allowed without the planted notes" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_CLEAN" "$(_c5_cmd "rm -f $GS_TGT_FWD/ghost-planted-sid.workflow-off")")")"

    # C13-5 — THE #2108 REGRESSION GUARD. The whole point of the narrowing is that a
    # subagent artifact named after an issue keeps writing. Asserted from INSIDE the
    # poisoned directory, because that is where a fix could most easily over-block.
    assert_eq "C13-5 issue-2108-survey.gh-env still writes (the #2108 false positive)" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/issue-2108-survey.gh-env")")")"
    assert_eq "C13-5 and on the bash route too" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "echo x > $GS_TGT_FWD/issue-2108-survey.gh-env")")")"

    # C13-5b — the fp-kebab-bash shape from cases-stem-rules.sh: an unobserved kebab
    # stem stays allowed on the bash spelling (R2b), and the planted value must not
    # widen that to every kebab name.
    assert_eq "C13-5b an UNplanted kebab stem is still allowed (bash, R2b)" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "echo x > $GS_TGT_FWD/ghost-name.workflow-off")")")"

    # C13-6 — a real session marker is blocked from the poisoned cwd as well, so the
    # new enumeration cannot have displaced the pre-existing protection.
    assert_eq "C13-6 the live session's own marker is still blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/wsid.workflow-off")")")"

    # C13-7 — PATTERN 1 (protection-fix-tests.md), the NEGATIVE assertion. Every row
    # above reads the hook's verdict only; a guard whose block text is right while the
    # forged file is already on disk would satisfy all of them. Here the tool action is
    # really EXECUTED whenever the hook approves, so the file itself is the assertion.
    printf '%s' "$GS_GENUINE" > "$GS_TGT_SH/ghost-planted-sid.workflow-off"
    rm -f "$GS_TGT_SH/ghost-planted-sid.off-clearance" "$GS_TGT_SH/issue-2108-survey.gh-env" 2>/dev/null || true

    assert_eq "C13-7a forged OVERWRITE of a ghost-sid marker is blocked" "block" \
        "$(_gs_gated_write "$GS_NOTES" wsid "$GS_TGT_FWD/ghost-planted-sid.workflow-off" \
            "$GS_TGT_SH/ghost-planted-sid.workflow-off" "FORGED-BY-2108-TEST")"
    assert_eq "C13-7a the seeded marker survived byte-for-byte" "$GS_GENUINE" \
        "$(_gs_read "$GS_TGT_SH/ghost-planted-sid.workflow-off")"

    assert_eq "C13-7b forged CREATE of a ghost-sid token is blocked" "block" \
        "$(_gs_gated_write "$GS_NOTES" wsid "$GS_TGT_FWD/ghost-planted-sid.off-clearance" \
            "$GS_TGT_SH/ghost-planted-sid.off-clearance" "FORGED-BY-2108-TEST")"
    assert_eq "C13-7b the forged token never appeared on disk" "<absent>" \
        "$(_gs_read "$GS_TGT_SH/ghost-planted-sid.off-clearance")"

    assert_eq "C13-7c rm of the ghost-sid marker is blocked" "block" \
        "$(_gs_gated_bash "$GS_NOTES" "rm -f $GS_TGT_FWD/ghost-planted-sid.workflow-off")"
    assert_eq "C13-7c the marker is still present and unchanged after the blocked rm" "$GS_GENUINE" \
        "$(_gs_read "$GS_TGT_SH/ghost-planted-sid.workflow-off")"

    # C13-7d/e — the harness must be ABLE to write and to delete, or every negative row
    # above would pass against a helper that quietly does nothing (false-green).
    assert_eq "C13-7d the allowed artifact write is approved" "approve" \
        "$(_gs_gated_write "$GS_NOTES" wsid "$GS_TGT_FWD/issue-2108-survey.gh-env" \
            "$GS_TGT_SH/issue-2108-survey.gh-env" "ARTIFACT-BODY")"
    assert_eq "C13-7d harness proof: the approved write really landed" "ARTIFACT-BODY" \
        "$(_gs_read "$GS_TGT_SH/issue-2108-survey.gh-env")"
    assert_eq "C13-7e the allowed artifact rm is approved" "approve" \
        "$(_gs_gated_bash "$GS_NOTES" "rm -f $GS_TGT_FWD/issue-2108-survey.gh-env")"
    assert_eq "C13-7e harness proof: the approved rm really deleted" "<absent>" \
        "$(_gs_read "$GS_TGT_SH/issue-2108-survey.gh-env")"

    # C13-8 — MIXED CASE in the planted value. The notes line is agent-written, and on a
    # case-folding filesystem `Ghost-Planted-Sid.workflow-off` and its lower-cased twin
    # are ONE file — so a case-sensitive comparison anywhere in the notes loop would
    # leave one spelling of the same forgery writable.
    assert_eq "C13-8 mixed-case notes value, lower-case target: Write is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES_MIXED" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/ghost-planted-sid.workflow-off")")")"
    assert_eq "C13-8 mixed-case notes value, lower-case target: bash is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES_MIXED" "$(_c5_cmd "echo x > $GS_TGT_FWD/ghost-planted-sid.off-clearance")")")"
    # The symmetric direction (CPR-ORTH): lower-case notes value, MIXED-case target.
    assert_eq "C13-8 lower-case notes value, mixed-case target: Write is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/Ghost-Planted-Sid.workflow-off")")")"
    assert_eq "C13-8 lower-case notes value, mixed-case target: bash is blocked" "block" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES" "$(_c5_cmd "echo x > $GS_TGT_FWD/Ghost-Planted-Sid.off-clearance")")")"
    # NEGATIVE CONTROL: folding must not widen the gate. From the SAME mixed-case notes
    # directory an unrelated artifact stem still writes, on both routes.
    assert_eq "C13-8 control: unrelated stem still allowed from the mixed-case fixture (Write)" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES_MIXED" "$(mk_edit_input Write "wsid" "$GS_TGT_FWD/issue-2108-survey.gh-env")")")"
    assert_eq "C13-8 control: unrelated stem still allowed from the mixed-case fixture (bash)" "approve" \
        "$(gate_decision "$(_gs_hook "$GS_NOTES_MIXED" "$(_c5_cmd "echo x > $GS_TGT_FWD/issue-2108-survey.gh-env")")")"

    # SKIPPED: a second agent process actually READING the planted file and acting on
    # the forged clearance.
    # Because: that reader is a separate live Claude Code session; this suite feeds
    # synthetic stdin to hook subprocesses and cannot observe a real session's decision.
    # L3 gap: whether the reader's own resolveSessionId path stays in agreement with the
    # enumeration once both are deployed — asserted statically by C14 pins instead.
}
