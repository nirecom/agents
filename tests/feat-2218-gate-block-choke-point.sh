#!/usr/bin/env bash
# tests/feat-2218-gate-block-choke-point.sh
# Tests: hooks/workflow-gate/handoff-record.js, hooks/workflow-gate.js, hooks/lib/handoff-artifact.js
# Tags: workflow-gate, handoff, choke-point, gate-block, fail-open, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 10 — a blocked gate is exactly the kind of event that never survives a compaction, and workflow-gate.js has twelve call sites for it. Recording inside block() itself (round1-fix C7) is what makes "every block is remembered" true by construction instead of by twelve separate edits that drift apart.

# TL3 gap: a real PreToolUse dispatch from Claude Code, and the block sites that need a live git repo (unstaged / size / extraction), are not driven here — the three scenarios below reach block() through the same choke point, which is what the recording depends on. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND: hooks/workflow-gate/handoff-record.js".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
GATE="$AGENTS_DIR/hooks/workflow-gate.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

RECORDER="hooks/workflow-gate/handoff-record.js"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 10, not yet implemented (write_code has not run)"
    return 1
}

# Drive the gate as Claude Code does: one hook input on stdin. tool_name Bash
# keeps runEarlyGate (Edit/Write only) out of the way, so the scenario reaches
# the block site the case is actually about.
run_gate() {
    local tmp="$1" sid="$2" cmd="$3"
    printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s","cwd":"%s"}}' "$sid" "$cmd" "$(node_path "$tmp")" \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID ENFORCE_WORKTREE=off \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 60 node "$GATE" 2>/dev/null
}

seed_state() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
writeState('$sid', createInitialState('$sid', { cwd: '/gate/fixture', git_branch: 'feature/gate' }));
markStep('$sid', 'workflow_init', 'complete');
" >/dev/null 2>&1
}

count_entries() {
    local tmp="$1" sid="$2" n
    if [ ! -f "$tmp/wf/$sid-handoff.md" ]; then printf '0'; return 0; fi
    n=$(grep -c 'gate:block' "$tmp/wf/$sid-handoff.md" 2>/dev/null)
    printf '%s' "${n:-0}"
}

CHAIN_CMD='echo \"<<WORKFLOW_RESEARCH_NOT_NEEDED: docs only>>\" && ls'

# C1 — the choke point, table driven. Three block sites that need no git repo:
# the sentinel-chain guard, the merge gate with no state, and the merge gate
# with user_verification still pending. All three must leave a record.
run_C1() {
    require_module "$RECORDER" || return 0
    local tmp out problems n
    tmp="$(make_tmp)"; problems=""
    seed_state "$tmp" "chain-sid"
    seed_state "$tmp" "uv-sid"
    out="$(run_gate "$tmp" "chain-sid" "$CHAIN_CMD")"
    case "$out" in *'"decision":"block"'*) : ;; *) problems="$problems sentinel-chain-not-blocked:'${out:0:120}'" ;; esac
    n="$(count_entries "$tmp" "chain-sid")"
    [ "$n" -ge 1 ] || problems="$problems sentinel-chain-not-recorded"
    out="$(run_gate "$tmp" "nostate-sid" "gh pr merge 123 --squash")"
    case "$out" in *'"decision":"block"'*) : ;; *) problems="$problems merge-nostate-not-blocked:'${out:0:120}'" ;; esac
    n="$(count_entries "$tmp" "nostate-sid")"
    [ "$n" -ge 1 ] || problems="$problems merge-nostate-not-recorded"
    out="$(run_gate "$tmp" "uv-sid" "gh pr merge 123 --squash")"
    case "$out" in *'"decision":"block"'*) : ;; *) problems="$problems merge-uv-not-blocked:'${out:0:120}'" ;; esac
    n="$(count_entries "$tmp" "uv-sid")"
    [ "$n" -ge 1 ] || problems="$problems merge-uv-not-recorded"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C1: three different block sites each record a gate:block entry — the recording lives in block(), not at one site"
    else
        fail "C1: —$problems"
    fi
}

# C2 — one fixed key, append-only history (round2-fix C6). Two blocks with
# different reasons both belong under `gate:block`; the resume view shows the
# reason that is still true, and the history keeps the one that came before.
run_C2() {
    require_module "$RECORDER" || return 0
    local tmp out problems n
    tmp="$(make_tmp)"; problems=""
    seed_state "$tmp" "two-sid"
    run_gate "$tmp" "two-sid" "$CHAIN_CMD" >/dev/null
    run_gate "$tmp" "two-sid" "gh pr merge 77 --squash" >/dev/null
    n="$(count_entries "$tmp" "two-sid")"
    [ "$n" -eq 2 ] || problems="$problems want-2-entries-got:$n"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff, renderHandoffForResume } = require('$AGENTS_DIR_NODE/hooks/lib/handoff-artifact');
const problems = [];
const doc = readHandoff('two-sid');
const all = [].concat.apply([], Object.values(doc.entriesByClass || {})).filter((e) => e.key === 'gate:block');
if (all.length !== 2) problems.push('history-length:' + all.length);
const rendered = renderHandoffForResume(doc);
const hits = (String(rendered).match(/gate:block/g) || []).length;
if (hits !== 1) problems.push('rendered-gate:block-lines:' + hits);
if (all.length === 2 && String(rendered).indexOf(all[0].summary) !== -1) problems.push('render-shows-the-superseded-reason');
if (all.length === 2 && String(rendered).indexOf(all[1].summary) === -1) problems.push('render-omits-the-newest-reason');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems render:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C2: two different reasons append two lines under the fixed key gate:block; the resume view renders only the newest"
    else
        fail "C2: —$problems"
    fi
}

# C3 — the same block twice is not news. noop-identical keeps a retry loop from
# filling the artifact with one repeated line.
run_C3() {
    require_module "$RECORDER" || return 0
    local tmp problems n
    tmp="$(make_tmp)"; problems=""
    seed_state "$tmp" "same-sid"
    run_gate "$tmp" "same-sid" "gh pr merge 55 --squash" >/dev/null
    run_gate "$tmp" "same-sid" "gh pr merge 55 --squash" >/dev/null
    run_gate "$tmp" "same-sid" "gh pr merge 55 --squash" >/dev/null
    n="$(count_entries "$tmp" "same-sid")"
    [ "$n" -eq 1 ] || problems="$problems repeated-identical-block-wrote:$n"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C3: an identical block repeated three times stays one line (noop-identical)"
    else
        fail "C3: —$problems"
    fi
}

# C4 — the invariant that makes this safe to put inside block(): an artifact
# write that fails must not change the gate's verdict. A directory planted at
# the artifact path is the cheapest unwritable target.
run_C4() {
    require_module "$RECORDER" || return 0
    local tmp out problems
    tmp="$(make_tmp)"; problems=""
    seed_state "$tmp" "unwritable-sid"
    mkdir -p "$tmp/wf/unwritable-sid-handoff.md"
    out="$(run_gate "$tmp" "unwritable-sid" "gh pr merge 99 --squash")"
    case "$out" in
        *'"decision":"block"'*) : ;;
        *) problems="$problems verdict-changed-by-a-failed-artifact-write:'${out:0:160}'" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C4: a failing handoff write leaves the block verdict and the hook protocol intact"
    else
        fail "C4: —$problems"
    fi
}

# C5 — the parse-failure block fires BEFORE _gateReportCtx has a session id, so
# the recorder is called with undefined. It must neither crash the hook nor
# invent an artifact under some placeholder name.
run_C5() {
    require_module "$RECORDER" || return 0
    local tmp out rc problems files
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    out=$(printf 'this is not json' | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID ENFORCE_WORKTREE=off \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$GATE" 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc"
    case "$out" in *'"decision":"block"'*) : ;; *) problems="$problems parse-failure-not-blocked:'${out:0:160}'" ;; esac
    files="$(ls "$tmp/wf" 2>/dev/null | grep -c 'handoff.md' || true)"
    [ "$files" -eq 0 ] || problems="$problems sessionless-block-created-an-artifact"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C5: the sessionless parse-failure block still blocks, exits 0, and writes no artifact"
    else
        fail "C5: —$problems"
    fi
}

run_C1
run_C2
run_C3
run_C4
run_C5

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
