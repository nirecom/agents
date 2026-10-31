#!/usr/bin/env bash
# tests/hooks/feat-2218-post-compact-writer.sh
# Tests: hooks/post-compact.js
# Tags: post-compact, handoff, class-b, writer, fail-open, regression-2218, regression-2652, state-handoff-record, progress-pressure, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 10 — compaction is the one event a resuming session needs recorded, and it is also the one event the compacted transcript can no longer describe. The PostCompact hook is the only code that runs at that instant, so the class B "compaction" record is written there (one event, through the shared entry point) rather than inferred later from a timestamp gap. #2652 moves the record from handoff.md into the state file as a state_handoff_record event; the burst record (key compaction-burst) is written by hooks/lib/progress-compaction.js, which the #2502 language gate keeps out of this bash header as a new js token.

# TL3 gap: a real Claude Code PostCompact dispatch is not driven here — the hook is fed the same stdin envelope Claude Code sends it, which is the contract the recording depends on; whether the platform actually fires PostCompact is not this file's claim. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): P1, P2, P3 and P8 are expected to FAIL until post-compact.js and progress-compaction.js write state_handoff_record events through hooks/lib/state-handoff-record.js; P4–P7 hold today.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/post-compact.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

# isolation (#2512): pin state and plans dirs file-wide; the per-call pins below still override them.
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans" "$_ISOLATION_TMP_ROOT/transcripts"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(node_path "$_ISOLATION_TMP_ROOT/transcripts")"
unset CLAUDE_CODE_SESSION_ID
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
cd "$_ISOLATION_TMP_ROOT" || exit 1

RECORD="hooks/lib/state-handoff-record.js"
STATE_IO="hooks/workflow-state/state-io"

require_module() {
    if [ -f "$SCRIPT_CHECKOUT_ROOT/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2652 S1/S3, not yet implemented (write_code has not run)"
    return 1
}

# Drive the hook exactly as Claude Code does: the PostCompact envelope on stdin.
run_hook() {
    local tmp="$1" sid="$2"
    printf '{"session_id":"%s"}' "$sid" \
        | env -u CLAUDE_CODE_SESSION_ID \
            WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 60 node "$HOOK" 2>/dev/null
}

# #2430: the compaction entry is an auto-record gated by the workflow active
# period, so a case that expects an entry seeds workflow_init complete first.
seed_active() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
writeState('$sid', createInitialState('$sid', { cwd: '/compact/fixture', git_branch: 'feature/compact' }));
markStep('$sid', 'workflow_init', 'complete');
" >/dev/null 2>&1
}

# The record's shape, read back from the state file's events (state-io, not a
# grep of the JSON) — the stored field names are the #2652 event contract.
inspect() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID SID="$sid" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readRawState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/$STATE_IO');
const sid = process.env.SID;
const problems = [];
const events = ((readRawState(sid) || {}).events || []);
const all = events.filter((x) => x && x.kind === 'state_handoff_record' && x.record_key === 'compaction');
if (all.length !== 1) problems.push('compaction-records:' + all.length);
else {
  const e = all[0];
  if (e.cls !== 'B') problems.push('cls:' + e.cls);
  if (e.origin !== 'auto-record') problems.push('origin:' + e.origin);
  if (e.provenance !== 'observed') problems.push('provenance:' + e.provenance);
  const s = String(e.summary);
  if (s.indexOf('context compaction occurred at ') !== 0) problems.push('summary:' + s);
  if (!/\d{4}-\d{2}-\d{2}T/.test(s)) problems.push('summary-carries-no-timestamp:' + s);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1
}

# P1 — the one-line addition. A compaction inside the workflow active period
# records one auto-record state_handoff_record (#2430: outside it, nothing is
# recorded — that half is pinned in tests/hooks/feat-2430-handoff-auto-record.sh).
run_P1() {
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "compact-sid-p1"
    out="$(run_hook "$tmp" "compact-sid-p1")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc"
    case "$out" in *'additionalContext'*) : ;; *) problems="$problems context-injection-lost:'${out:0:160}'" ;; esac
    out="$(inspect "$tmp" "compact-sid-p1")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P1: PostCompact records one class B compaction state_handoff_record summarising the moment, and still injects its context"
    else
        fail "P1: —$problems"
    fi
}

# P2 — the dedup contract at THIS call site. Two compactions in one session are
# two distinct events, so the second must append rather than collapse: the key
# is fixed, but the timestamp in the summary differs, so noop-identical must not
# fire. The --from render folds them to the newest per (at_step, record_key).
# (The collapse case is P3.)
run_P2() {
    require_module "$RECORD" || return 0
    local tmp problems out
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "twice-sid-p2"
    run_hook "$tmp" "twice-sid-p2" >/dev/null
    run_hook "$tmp" "twice-sid-p2" >/dev/null
    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readRawState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/$STATE_IO');
const { readStateHandoff, renderStateHandoffForResume } = require('$SCRIPT_CHECKOUT_ROOT_NODE/$RECORD');
const problems = [];
const all = ((readRawState('twice-sid-p2') || {}).events || []).filter((x) => x && x.kind === 'state_handoff_record' && x.record_key === 'compaction');
if (all.length !== 2) problems.push('stored-compaction-records:' + all.length);
const rendered = String(renderStateHandoffForResume(readStateHandoff('twice-sid-p2').entries));
const hits = (rendered.match(/compaction occurred at/g) || []).length;
if (hits !== 1) problems.push('rendered-compaction-lines:' + hits);
if (all.length >= 2 && rendered.indexOf(all[all.length - 1].summary) === -1) problems.push('render-omits-the-newest-compaction');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems render:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P2: a second compaction under the same fixed key still renders as exactly one latest-wins line"
    else
        fail "P2: —$problems"
    fi
}

# P3 — the same observation re-offered at this call site collapses. Driven
# through the entry point with the record the hook produces, because two real
# hook runs can never share a timestamp; what is under test is that
# post-compact.js goes through appendStateHandoffRecord (which owns
# noop-identical) and not through a private append of its own.
run_P3() {
    require_module "$RECORD" || return 0
    local tmp out problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "dedup-sid-p3"
    run_hook "$tmp" "dedup-sid-p3" >/dev/null
    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readRawState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/$STATE_IO');
const { appendStateHandoffRecord } = require('$SCRIPT_CHECKOUT_ROOT_NODE/$RECORD');
const problems = [];
const compactions = () => ((readRawState('dedup-sid-p3') || {}).events || []).filter((x) => x && x.kind === 'state_handoff_record' && x.record_key === 'compaction');
const seed = compactions()[0];
if (!seed) { process.stdout.write('BAD:post-compact-wrote-no-compaction-record-to-re-offer'); process.exit(0); }
const r = appendStateHandoffRecord('dedup-sid-p3', { cls: seed.cls, step: seed.at_step, key: seed.record_key, summary: seed.summary, pointer: seed.pointer, origin: seed.origin });
if (!r || r.written !== false || r.reason !== 'noop-identical') problems.push('re-observation-result:' + JSON.stringify(r));
const n = compactions().length;
if (n !== 1) problems.push('records-after-re-observation:' + n);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems $out"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P3: the record post-compact.js writes collapses to noop-identical when re-observed — it goes through the shared entry point"
    else
        fail "P3: —$problems"
    fi
}

# P4 — the invariant. PostCompact's job is context re-injection; a breadcrumb
# that cannot be written is a lost breadcrumb, never a lost re-injection. The
# old target (a directory at handoff.md) has no state-file counterpart: the
# record now lives in the same state file the hook reads for its own context.
# A state file holding garbage is the cheapest record that cannot be written
# (readRawState fails, so the entry point refuses), and the hook must still
# answer with its injection envelope.
run_P4() {
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    printf 'not json {' >"$tmp/wf/unwritable-sid-p4.json"
    out="$(run_hook "$tmp" "unwritable-sid-p4")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit-changed-by-a-failed-record-write:$rc"
    case "$out" in *'additionalContext'*) : ;; *) problems="$problems injection-lost-to-a-failed-record-write:'${out:0:160}'" ;; esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P4: a record that cannot be written leaves PostCompact's exit code and additionalContext intact"
    else
        fail "P4: —$problems"
    fi
}

# P5 — no session id means no state file to write to. The hook already returns
# "{}" there; the recording must not invent a placeholder-named file.
run_P5() {
    local tmp out rc problems files
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    out=$(printf '{}' | env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$HOOK" 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc"
    [ "$out" = "{}" ] || problems="$problems sessionless-output:'${out:0:120}'"
    files="$(find "$tmp/wf" -type f 2>/dev/null | grep -c '' || true)"
    [ "$files" -eq 0 ] || problems="$problems sessionless-compaction-created-a-file:$files"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P5: a compaction with no session id writes no state file and still returns {}"
    else
        fail "P5: —$problems"
    fi
}

# --- #2594 session-progress.md (appended here: TL3-hook-post-compact.sh is RUN_TL3-gated) ---
# PostCompact cannot deliver a request reliably, so the hook only (a) points at
# session-progress.md and (b) leaves pending state in <sid>.control/progress-pressure.json
# for hooks/progress-nudge.js. Field names are the implementation's; the probe
# below matches them by role (a truthy *pending* key, a *compaction* time array).
pressure_probe() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID SID="$sid" PP="$tmp/wf/$sid.control/progress-pressure.json" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const fs = require('fs');
let j; try { j = JSON.parse(fs.readFileSync(process.env.PP, 'utf8')); } catch (e) { process.stdout.write('no-file'); process.exit(0); }
const walk = (o, pre, out) => { if (o && typeof o === 'object' && !Array.isArray(o)) for (const k of Object.keys(o)) { out.push([pre + k, o[k]]); walk(o[k], pre + k + '.', out); } return out; };
const kv = walk(j, '', []);
const pend4d = kv.some(([k, v]) => /pending/i.test(k) && !/burst|suggest/i.test(k) && !!v);
const burst = kv.some(([k, v]) => /burst|suggest/i.test(k) && /pending/i.test(k) && !!v);
const times = kv.filter(([k, v]) => /compaction/i.test(k) && Array.isArray(v)).map(([, v]) => v.length);
process.stdout.write('pending4d=' + pend4d + ';burst=' + burst + ';times=' + (times.length ? Math.max.apply(null, times) : -1));
" 2>&1
}

# burst_records <tmp> <sid> — auto-record state_handoff_records other than the
# per-compaction one: "0", or "<n>:<their record_keys>".
burst_records() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID SID="$sid" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readRawState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/$STATE_IO');
const events = ((readRawState(process.env.SID) || {}).events || []);
const rest = events.filter((x) => x && x.kind === 'state_handoff_record' && x.origin === 'auto-record' && x.record_key !== 'compaction');
process.stdout.write(rest.length ? rest.length + ':' + rest.map((x) => x.record_key).join(',') : '0');
" 2>&1
}

# P6 — the re-injected context names session-progress.md (rootSid == sid without inheritance)
# and the section to read first; one compaction sets the 4d pending and one time.
run_P6() {
    local tmp out problems probe
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "pc-sid-p6"
    out="$(run_hook "$tmp" "pc-sid-p6")"
    case "$out" in *'pc-sid-p6-session-progress.md'*) : ;; *) problems="$problems no-progress-path:'${out:0:200}'" ;; esac
    case "$out" in *'(read \"Current state\" first)'*|*'(read "Current state" first)'*) : ;; *) problems="$problems no-first-section-name" ;; esac
    probe="$(pressure_probe "$tmp" "pc-sid-p6")"
    [ "$probe" = "pending4d=true;burst=false;times=1" ] || problems="$problems pressure:'$probe'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P6: PostCompact points at <sid>-session-progress.md (read Current state first), sets the 4d pending and records one compaction time"
    else
        fail "P6: —$problems"
    fi
}

# P7 — below the burst threshold (a burst is 8 or more in 30 min): three compactions
# record three times, no burst suggestion and no burst auto-record.
run_P7() {
    local tmp problems probe n i
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "pc-sid-p7"
    for i in 1 2 3; do run_hook "$tmp" "pc-sid-p7" >/dev/null; done
    probe="$(pressure_probe "$tmp" "pc-sid-p7")"
    case "$probe" in *'burst=false;times=3') : ;; *) problems="$problems pressure:'$probe'" ;; esac
    n="$(burst_records "$tmp" "pc-sid-p7")"
    [ "$n" = "0" ] || problems="$problems burst-records:$n"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P7: three compactions in 30 min stay below the burst threshold — no suggestion pending, no burst record"
    else
        fail "P7: —$problems"
    fi
}

# P8 — the threshold boundary (BURST_THRESHOLD 7): seven compactions in a row stay
# below it (4d pending, no burst, no record); the eighth crosses it once, so exactly
# one burst auto-record line is written and the suggestion is pending; the
# compactions after the crossing do not repeat the record in the same session.
run_P8() {
    local tmp problems probe n i
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "pc-sid-p8"
    for i in 1 2 3 4 5 6 7; do run_hook "$tmp" "pc-sid-p8" >/dev/null; done
    probe="$(pressure_probe "$tmp" "pc-sid-p8")"
    [ "$probe" = "pending4d=true;burst=false;times=7" ] || problems="$problems after-7-pressure:'$probe'"
    n="$(burst_records "$tmp" "pc-sid-p8")"
    [ "$n" = "0" ] || problems="$problems after-7-burst-records:$n"
    run_hook "$tmp" "pc-sid-p8" >/dev/null
    probe="$(pressure_probe "$tmp" "pc-sid-p8")"
    case "$probe" in *'burst=true;times=8') : ;; *) problems="$problems after-8-pressure:'$probe'" ;; esac
    n="$(burst_records "$tmp" "pc-sid-p8")"
    [ "$n" = "1:compaction-burst" ] || problems="$problems after-8-burst-records:$n"
    for i in 1 2; do run_hook "$tmp" "pc-sid-p8" >/dev/null; done
    n="$(burst_records "$tmp" "pc-sid-p8")"
    [ "$n" = "1:compaction-burst" ] || problems="$problems after-10-burst-records:$n"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P8: seven compactions stay below the burst threshold; the eighth writes one compaction-burst state_handoff_record and sets the suggestion pending, once per session"
    else
        fail "P8: —$problems"
    fi
}

run_P1
run_P2
run_P3
run_P4
run_P5
run_P6
run_P7
run_P8

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
