#!/usr/bin/env bash
# tests/feat-2218-post-compact-writer.sh
# Tests: hooks/post-compact.js, hooks/lib/handoff-artifact.js
# Tags: post-compact, handoff, class-b, writer, fail-open, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 10 — compaction is the one event the artifact exists for, and it is also the one event the compacted transcript can no longer describe. The PostCompact hook is the only code that runs at that instant, so the class B "compaction" entry is written there (one line, through the shared writer) rather than inferred later from a timestamp gap.

# TL3 gap: a real Claude Code PostCompact dispatch is not driven here — the hook is fed the same stdin envelope Claude Code sends it, which is the contract the recording depends on; whether the platform actually fires PostCompact is not this file's claim. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND: hooks/lib/handoff-artifact.js".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
HOOK="$AGENTS_DIR/hooks/post-compact.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

ARTIFACT="hooks/lib/handoff-artifact.js"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 10, not yet implemented (write_code has not run)"
    return 1
}

# Drive the hook exactly as Claude Code does: the PostCompact envelope on stdin.
run_hook() {
    local tmp="$1" sid="$2"
    printf '{"session_id":"%s"}' "$sid" \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 60 node "$HOOK" 2>/dev/null
}

# The entry's shape, read back through the module's own reader rather than by
# grepping the file — the grammar is the writer's business, not this file's.
inspect() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID SID="$sid" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff } = require('$AGENTS_DIR_NODE/$ARTIFACT');
const sid = process.env.SID;
const problems = [];
const doc = readHandoff(sid);
const all = [].concat.apply([], Object.values(doc.entriesByClass || {})).filter((x) => x.key === 'compaction');
if (all.length !== 1) problems.push('compaction-entries:' + all.length);
else {
  const e = all[0];
  if (e.class !== 'B') problems.push('class:' + e.class);
  const s = String(e.summary);
  if (s.indexOf('context compaction occurred at ') !== 0) problems.push('summary:' + s);
  if (!/\d{4}-\d{2}-\d{2}T/.test(s)) problems.push('summary-carries-no-timestamp:' + s);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1
}

count_entries() {
    local tmp="$1" sid="$2" n
    if [ ! -f "$tmp/wf/$sid-handoff.md" ]; then printf '0'; return 0; fi
    n=$(grep -c 'compaction' "$tmp/wf/$sid-handoff.md" 2>/dev/null)
    printf '%s' "${n:-0}"
}

# P1 — the one-line addition. A compaction with no workflow state at all still
# records: the artifact is what a stateless session has left to hand over.
run_P1() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    out="$(run_hook "$tmp" "compact-sid-p1")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc"
    case "$out" in *'additionalContext'*) : ;; *) problems="$problems context-injection-lost:'${out:0:160}'" ;; esac
    out="$(inspect "$tmp" "compact-sid-p1")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P1: PostCompact records one class B compaction entry summarising the moment, and still injects its context"
    else
        fail "P1: —$problems"
    fi
}

# P2 — the dedup contract at THIS call site. Two compactions in one session are
# two distinct events, so the second must append rather than collapse: the key
# is fixed, but the timestamp in the summary differs, so noop-identical must not
# fire. (The collapse case is P3.)
run_P2() {
    require_module "$ARTIFACT" || return 0
    local tmp problems n out
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    run_hook "$tmp" "twice-sid-p2" >/dev/null
    run_hook "$tmp" "twice-sid-p2" >/dev/null
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff, renderHandoffForResume } = require('$AGENTS_DIR_NODE/$ARTIFACT');
const problems = [];
const doc = readHandoff('twice-sid-p2');
const all = [].concat.apply([], Object.values(doc.entriesByClass || {})).filter((x) => x.key === 'compaction');
if (all.length < 1) problems.push('no-entry-at-all');
const rendered = String(renderHandoffForResume(doc));
const hits = (rendered.match(/compaction/g) || []).length;
if (hits !== 1) problems.push('rendered-compaction-lines:' + hits);
if (all.length >= 2 && rendered.indexOf(all[all.length - 1].summary) === -1) problems.push('render-omits-the-newest-compaction');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems render:'$out'"
    n="$(count_entries "$tmp" "twice-sid-p2")"
    [ "$n" -ge 1 ] || problems="$problems nothing-written:$n"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P2: a second compaction under the same fixed key still renders as exactly one latest-wins line"
    else
        fail "P2: —$problems"
    fi
}

# P3 — the same observation re-offered at this call site collapses. Driven
# through the writer with the entry the hook produces, because two real hook
# runs can never share a timestamp; what is under test is that post-compact.js
# goes through appendHandoffEntry (which owns noop-identical) and not through a
# private append of its own.
run_P3() {
    require_module "$ARTIFACT" || return 0
    local tmp out problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    run_hook "$tmp" "dedup-sid-p3" >/dev/null
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff, appendHandoffEntry } = require('$AGENTS_DIR_NODE/$ARTIFACT');
const problems = [];
const before = readHandoff('dedup-sid-p3');
const seed = [].concat.apply([], Object.values(before.entriesByClass || {})).filter((x) => x.key === 'compaction')[0];
if (!seed) { process.stdout.write('BAD:post-compact-wrote-no-compaction-entry-to-re-offer'); process.exit(0); }
const r = appendHandoffEntry('dedup-sid-p3', { cls: seed.class, step: seed.step, key: seed.key, summary: seed.summary, pointer: seed.pointer, origin: seed.origin });
if (!r || r.written !== false || r.reason !== 'noop-identical') problems.push('re-observation-result:' + JSON.stringify(r));
const after = readHandoff('dedup-sid-p3');
const n = [].concat.apply([], Object.values(after.entriesByClass || {})).filter((x) => x.key === 'compaction').length;
if (n !== 1) problems.push('entries-after-re-observation:' + n);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems $out"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P3: the entry post-compact.js writes collapses to noop-identical when re-observed — it goes through the shared writer"
    else
        fail "P3: —$problems"
    fi
}

# P4 — the invariant. PostCompact's job is context re-injection; a breadcrumb
# that cannot be written is a lost breadcrumb, never a lost re-injection. A
# directory at the artifact path is the cheapest unwritable target.
run_P4() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf/unwritable-sid-p4-handoff.md"
    out="$(run_hook "$tmp" "unwritable-sid-p4")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit-changed-by-a-failed-artifact-write:$rc"
    case "$out" in *'additionalContext'*) : ;; *) problems="$problems injection-lost-to-a-failed-artifact-write:'${out:0:160}'" ;; esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P4: a failing handoff write leaves PostCompact's exit code and additionalContext intact"
    else
        fail "P4: —$problems"
    fi
}

# P5 — no session id means no artifact to write to. The hook already returns
# "{}" there; the recording must not invent a placeholder-named file.
run_P5() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems files
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    out=$(printf '{}' | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$HOOK" 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc"
    [ "$out" = "{}" ] || problems="$problems sessionless-output:'${out:0:120}'"
    files="$(ls "$tmp/wf" 2>/dev/null | grep -c 'handoff.md' || true)"
    [ "$files" -eq 0 ] || problems="$problems sessionless-compaction-created-an-artifact"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P5: a compaction with no session id writes no artifact and still returns {}"
    else
        fail "P5: —$problems"
    fi
}

run_P1
run_P2
run_P3
run_P4
run_P5

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
