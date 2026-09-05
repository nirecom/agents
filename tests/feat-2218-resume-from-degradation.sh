#!/usr/bin/env bash
# tests/feat-2218-resume-from-degradation.sh
# Tests: bin/resume-session-detect, bin/lib/resume-session/upstream-view.js, bin/lib/resume-session/transcript-fallback.js, hooks/lib/session-title.js, hooks/workflow-state/inheritance/candidates.js
# Tags: resume-session, session-upstream, degradation, transcript-tail, granularity, regression-2218, scope:issue-specific, pwsh-not-required, TL2

# Issue #2218 Step 5 / Step 11 — `--from <sid>` must degrade rather than refuse: a 7-day-expired state file still has readable plan artifacts, and a transcript still has the last few turns. Each degradation level has its own honest message, and none of them may fabricate a `not-resumable` verdict for what is really a TTL deletion.

# TL3 gap: the Task-tool dispatch that summarizes the transcript tail, and the merge of that summary into render.js output, are not exercised here — only the deterministic CLI half (path resolution, cap, and the no-raw-text contract). Recorded as a TL3/TL4 gap in docs/architecture/claude-code/e2e-testing.md per Step 14. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): the --from cases are expected to FAIL with "MODULE NOT FOUND"; F1 pins today's no-arg contract and must stay green throughout.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
CLI="$AGENTS_DIR/bin/resume-session-detect"
FIXTURE="$AGENTS_DIR/tests/fixtures/feat-2218-sample-transcript.jsonl"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

VIEW="bin/lib/resume-session/upstream-view.js"
TAIL="bin/lib/resume-session/transcript-fallback.js"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 5/11, not yet implemented (write_code has not run)"
    return 1
}

init_repo() {
    git init -q "$1" 2>/dev/null
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config user.email 't@example.com'
    git -C "$1" config user.name 'fixture'
    git -C "$1" config commit.gpgsign false
    printf 'seed\n' > "$1/f.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m init
}

# F1 — the no-arg contract. hooks/session-start.js spawns this CLI for its
# RESUME HINT, so all three existing result shapes must keep their exact keys
# once --from / --list are added. This case is green today by design.
run_F1() {
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="f1-sess" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
writeState('f1-sess', createInitialState('f1-sess', { cwd: '/f1', git_branch: 'main' }));
markStep('f1-sess', 'write_tests', 'in_progress');
writeState('f1-sentinel', createInitialState('f1-sentinel', { cwd: '/f1', git_branch: 'main' }));
markStep('f1-sentinel', 'review_tests', 'in_progress');
" >/dev/null 2>&1
    probe_keys() {
        env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$1" \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 30 node "$CLI" 2>/dev/null
    }
    out="$(probe_keys f1-sess)"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems skill-exit:$rc"
    case "$out" in
        *'"type":"skill"'*'"step":"write_tests"'*'"skill":"write-tests"'*) : ;;
        *) problems="$problems skill-shape:'$out'" ;;
    esac
    out="$(probe_keys f1-sentinel)"
    case "$out" in
        *'"type":"sentinel-wait"'*'"step":"review_tests"'*'"hint":"review_tests"'*) : ;;
        *) problems="$problems sentinel-shape:'$out'" ;;
    esac
    out="$(probe_keys f1-absent)"
    case "$out" in
        *'"type":"none"'*'"reason":"no_state"'*) : ;;
        *) problems="$problems none-shape:'$out'" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F1: the no-arg JSON keys for skill / sentinel-wait / none are unchanged"
    else
        fail "F1: no-arg contract drifted —$problems"
    fi
}

# F2 — the four availability values. `artifacts-only` is the one that used to
# lie: calling adoptState there produces "not resumable", when the truth is that
# the state file aged out and the artifacts are still perfectly readable.
run_F2() {
    require_module "$VIEW" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f2" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const dir = '$(node_path "$tmp")/wf';
fs.mkdirSync(dir, { recursive: true });
writeState('heir-f2', createInitialState('heir-f2', { cwd: '/heir', git_branch: 'main' }));
writeState('full-f2', createInitialState('full-f2', { cwd: '/heir', git_branch: 'main' }));
markStep('full-f2', 'workflow_init', 'complete');
fs.writeFileSync(path.join(dir, 'full-f2-intent.md'), 'intent body' + String.fromCharCode(10));
fs.writeFileSync(path.join(dir, 'expired-f2-intent.md'), 'intent body' + String.fromCharCode(10));
fs.writeFileSync(path.join(dir, 'expired-f2-detail.md'), 'detail body' + String.fromCharCode(10));
writeState('stateonly-f2', createInitialState('stateonly-f2', { cwd: '/heir', git_branch: 'main' }));
markStep('stateonly-f2', 'workflow_init', 'complete');
" >/dev/null 2>&1
    from() {
        env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f2" \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 60 node "$CLI" --from "$1" 2>&1
    }
    out="$(from full-f2)"
    case "$out" in *state-and-artifacts*) : ;; *) problems="$problems full:'${out:0:160}'" ;; esac
    out="$(from expired-f2)"
    case "$out" in *artifacts-only*) : ;; *) problems="$problems expired-availability:'${out:0:160}'" ;; esac
    case "$out" in *state_expired*) : ;; *) problems="$problems expired-inherit-result:'${out:0:160}'" ;; esac
    case "$out" in *not-resumable*|*'not resumable'*) problems="$problems expired-claims-not-resumable" ;; *) : ;; esac
    case "$out" in *'"attempted":false'*|*'"attempted": false'*) : ;; *) problems="$problems expired-attempted-flag:'${out:0:160}'" ;; esac
    out="$(from stateonly-f2)"
    case "$out" in *state-only*) : ;; *) problems="$problems stateonly-availability:'${out:0:160}'" ;; esac
    case "$out" in *intent-artifact-missing*) : ;; *) problems="$problems stateonly-reason-not-verbatim:'${out:0:160}'" ;; esac
    from ghost-f2 >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 3 ] || problems="$problems unknown-sid-exit:$rc"
    if [ -f "$tmp/wf/expired-f2.json" ]; then problems="$problems adoptState-wrote-a-state-file-for-the-expired-session"; fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F2: all four availability values, artifacts-only never adopts, unknown-sid exits 3"
    else
        fail "F2: unexpected degradation behaviour —$problems"
    fi
}

# F3 — granularity actually reaches adopt-session-state. The observable
# difference is in the heir's state: a proven-equivalent sibling worktree keeps
# the worktree-dependent steps, a divergent one reverts them.
run_F3() {
    require_module "$VIEW" || return 0
    local tmp out problems
    tmp="$(make_tmp)"; problems=""
    init_repo "$tmp/base"
    git -C "$tmp/base" worktree add -q -b feature/twin "$tmp/twin" 2>/dev/null
    git -C "$tmp/base" worktree add -q -b feature/drift "$tmp/drift" 2>/dev/null
    if [ ! -d "$tmp/twin" ] || [ ! -d "$tmp/drift" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "F3: fixture setup failed — could not create the linked worktrees"
        return 0
    fi
    printf 'diverged\n' > "$tmp/drift/extra.txt"
    git -C "$tmp/drift" add -A
    git -C "$tmp/drift" commit -q -m drift
    seed_pair() {
        env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$1" \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 30 node -e "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const dir = '$(node_path "$tmp")/wf';
fs.mkdirSync(dir, { recursive: true });
writeState('$1', createInitialState('$1', { cwd: '$2', git_branch: 'feature/heir' }));
writeState('$3', createInitialState('$3', { cwd: '$(node_path "$tmp")/base', git_branch: 'feature/base' }));
for (const s of ['workflow_init', 'clarify_intent', 'detail', 'branching_complete', 'write_tests']) markStep('$3', s, 'complete');
fs.writeFileSync(path.join(dir, '$3' + '-intent.md'), 'intent body' + String.fromCharCode(10));
" >/dev/null 2>&1
    }
    read_step() {
        env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$1" \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 30 node -e "
const { readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const s = readState('$1') || {};
process.stdout.write(String(((s.steps || {})['$2'] || {}).status || 'pending'));
" 2>/dev/null
    }
    seed_pair heir-twin "$(node_path "$tmp/twin")" donor-twin
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-twin" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 90 node "$CLI" --from donor-twin >/dev/null 2>&1
    out="$(read_step heir-twin write_tests)"
    [ "$out" = "complete" ] || problems="$problems equivalent-sibling-did-not-inherit-full:write_tests=$out"
    seed_pair heir-drift "$(node_path "$tmp/drift")" donor-drift
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-drift" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 90 node "$CLI" --from donor-drift >/dev/null 2>&1
    out="$(read_step heir-drift write_tests)"
    [ "$out" = "pending" ] || problems="$problems divergent-sibling-inherited-a-worktree-step:write_tests=$out"
    out="$(read_step heir-drift detail)"
    [ "$out" = "complete" ] || problems="$problems divergent-sibling-lost-the-plan-steps:detail=$out"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F3: a proven-equivalent sibling worktree inherits full state; a divergent one degrades to context-independent-only"
    else
        fail "F3: granularity did not reach adopt-session-state —$problems"
    fi
}

# F4 — deterministic jsonl resolution (round2-fix C9). _getJsonlPath prefers
# CLAUDE_SESSION_JSONL_PATH, which points at the DOWNSTREAM session's own
# transcript; composing the path from _getTranscriptBase + _encodeCwd is the
# only way `--from` reads the upstream session's file instead.
run_F4() {
    require_module "$TAIL" || return 0
    local tmp out problems
    tmp="$(make_tmp)"; problems=""
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const t = require('$AGENTS_DIR_NODE/hooks/lib/session-title');
const fs = require('fs');
const problems = [];
if (typeof t._getTranscriptBase !== 'function') problems.push('session-title.js does not export _getTranscriptBase');
const src = fs.readFileSync('$AGENTS_DIR_NODE/$TAIL', 'utf8');
if (src.indexOf('_getJsonlPath') !== -1) problems.push('transcript-fallback.js still routes through _getJsonlPath');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems static:'$out'"
    # Behavioural half: a decoy on CLAUDE_SESSION_JSONL_PATH must be ignored.
    local upcwd encoded
    upcwd="$(node_path "$tmp/upstream-repo")"
    mkdir -p "$tmp/upstream-repo"
    encoded=$(env -u CLAUDE_SESSION_ID "$RWT" 30 node -e "
const { _encodeCwd } = require('$AGENTS_DIR_NODE/hooks/lib/session-title');
process.stdout.write(_encodeCwd('$upcwd'));
" 2>/dev/null)
    mkdir -p "$tmp/transcripts/$encoded"
    cp "$FIXTURE" "$tmp/transcripts/$encoded/up-f4.jsonl"
    printf '{"type":"user","sessionId":"decoy","message":{"role":"user","content":"DECOY-SHOULD-NOT-BE-READ"}}\n' > "$tmp/decoy.jsonl"
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f4" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const dir = '$(node_path "$tmp")/wf';
fs.mkdirSync(dir, { recursive: true });
writeState('heir-f4', createInitialState('heir-f4', { cwd: '$upcwd', git_branch: 'main' }));
fs.writeFileSync(path.join(dir, 'up-f4-intent.md'), 'intent body' + String.fromCharCode(10));
writeState('up-f4', createInitialState('up-f4', { cwd: '$upcwd', git_branch: 'main' }));
markStep('up-f4', 'workflow_init', 'complete');
" >/dev/null 2>&1
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f4" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$tmp/transcripts" \
        CLAUDE_SESSION_JSONL_PATH="$tmp/decoy.jsonl" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node "$CLI" --from up-f4 2>&1)
    local scratch
    scratch=$(env -u CLAUDE_SESSION_ID OUT="$out" "$RWT" 30 node -e "
let j = null;
try { j = JSON.parse(process.env.OUT); } catch (e) {}
const t = (j && (j.transcript_tail || (j.upstream && j.upstream.transcript_tail))) || {};
process.stdout.write(String(t.path || ''));
" 2>/dev/null)
    if [ -z "$scratch" ]; then
        problems="$problems no-transcript_tail.path-in:'${out:0:200}'"
    elif [ ! -f "$scratch" ]; then
        problems="$problems scratch-file-missing:$scratch"
    else
        grep -q 'FEAT2218-TAIL-TOKEN' "$scratch" || problems="$problems scratch-does-not-hold-the-upstream-transcript"
        grep -q 'DECOY-SHOULD-NOT-BE-READ' "$scratch" && problems="$problems followed-CLAUDE_SESSION_JSONL_PATH"
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F4: the upstream jsonl path is composed deterministically and ignores CLAUDE_SESSION_JSONL_PATH"
    else
        fail "F4: —$problems"
    fi
}

# F5 — the 200KB cap, asserted on the scratch file the CLI writes (round4-fix
# C9 moved the cap to the write step). An unbounded tail would blow up the
# subagent's input on a long session.
run_F5() {
    require_module "$TAIL" || return 0
    local tmp out problems upcwd encoded scratch size
    tmp="$(make_tmp)"; problems=""
    upcwd="$(node_path "$tmp/upstream-repo")"
    mkdir -p "$tmp/upstream-repo"
    encoded=$(env -u CLAUDE_SESSION_ID "$RWT" 30 node -e "
const { _encodeCwd } = require('$AGENTS_DIR_NODE/hooks/lib/session-title');
process.stdout.write(_encodeCwd('$upcwd'));
" 2>/dev/null)
    mkdir -p "$tmp/transcripts/$encoded"
    env -u CLAUDE_SESSION_ID "$RWT" 30 node -e "
const fs = require('fs');
const filler = JSON.stringify({ type: 'user', sessionId: 'up-f5', message: { role: 'user', content: 'x'.repeat(400) } });
const lines = [];
for (let i = 0; i < 3000; i++) lines.push(filler);
fs.writeFileSync('$(node_path "$tmp")/transcripts/$encoded/up-f5.jsonl', lines.join(String.fromCharCode(10)) + String.fromCharCode(10) + fs.readFileSync('$(node_path "$FIXTURE")', 'utf8'));
" >/dev/null 2>&1
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f5" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const dir = '$(node_path "$tmp")/wf';
fs.mkdirSync(dir, { recursive: true });
writeState('heir-f5', createInitialState('heir-f5', { cwd: '$upcwd', git_branch: 'main' }));
fs.writeFileSync(path.join(dir, 'up-f5-intent.md'), 'intent body' + String.fromCharCode(10));
writeState('up-f5', createInitialState('up-f5', { cwd: '$upcwd', git_branch: 'main' }));
markStep('up-f5', 'workflow_init', 'complete');
" >/dev/null 2>&1
    out=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f5" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$tmp/transcripts" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node "$CLI" --from up-f5 2>&1)
    scratch=$(env -u CLAUDE_SESSION_ID OUT="$out" "$RWT" 30 node -e "
let j = null;
try { j = JSON.parse(process.env.OUT); } catch (e) {}
const t = (j && (j.transcript_tail || (j.upstream && j.upstream.transcript_tail))) || {};
process.stdout.write(String(t.path || ''));
" 2>/dev/null)
    if [ -z "$scratch" ] || [ ! -f "$scratch" ]; then
        problems="$problems no-scratch-file:'${out:0:200}'"
    else
        size=$(env -u CLAUDE_SESSION_ID P="$scratch" "$RWT" 30 node -e "
const fs = require('fs');
process.stdout.write(String(fs.statSync(process.env.P).size));
" 2>/dev/null)
        [ "$size" -le 204800 ] || problems="$problems scratch-exceeds-200KB:$size"
        [ "$size" -gt 102400 ] || problems="$problems scratch-suspiciously-small:$size"
        grep -q 'FEAT2218-TAIL-TOKEN' "$scratch" || problems="$problems tail-is-not-the-end-of-the-file"
        case "$(basename "$scratch")" in
            resume-tail-up-f5-*.txt) : ;;
            *) problems="$problems scratch-name:'$(basename "$scratch")'" ;;
        esac
        out=$(env -u CLAUDE_SESSION_ID P="$scratch" "$RWT" 30 node -e "
const os = require('os');
const path = require('path');
const rel = path.relative(os.tmpdir(), process.env.P);
process.stdout.write(rel.indexOf('..') === 0 ? 'OUTSIDE' : 'INSIDE');
" 2>/dev/null)
        [ "$out" = "INSIDE" ] || problems="$problems scratch-not-under-os.tmpdir:$scratch"
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F5: the tail is capped at 200KB and written to os.tmpdir()/resume-tail-<upstreamSid>-<pid>.txt"
    else
        fail "F5: —$problems"
    fi
}

# F6 — the containment contract (round4-fix C9). The raw jsonl must never enter
# the downstream session's conversation context, so the CLI's stdout may carry a
# path and nothing that could hold transcript text.
run_F6() {
    require_module "$TAIL" || return 0
    local tmp out problems upcwd encoded verdict
    tmp="$(make_tmp)"; problems=""
    upcwd="$(node_path "$tmp/upstream-repo")"
    mkdir -p "$tmp/upstream-repo"
    encoded=$(env -u CLAUDE_SESSION_ID "$RWT" 30 node -e "
const { _encodeCwd } = require('$AGENTS_DIR_NODE/hooks/lib/session-title');
process.stdout.write(_encodeCwd('$upcwd'));
" 2>/dev/null)
    mkdir -p "$tmp/transcripts/$encoded"
    cp "$FIXTURE" "$tmp/transcripts/$encoded/up-f6.jsonl"
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f6" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const fs = require('fs');
const path = require('path');
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const dir = '$(node_path "$tmp")/wf';
fs.mkdirSync(dir, { recursive: true });
writeState('heir-f6', createInitialState('heir-f6', { cwd: '$upcwd', git_branch: 'main' }));
for (const sid of ['up-f6', 'nocwd-f6']) {
  fs.writeFileSync(path.join(dir, sid + '-intent.md'), 'intent body' + String.fromCharCode(10));
}
writeState('up-f6', createInitialState('up-f6', { cwd: '$upcwd', git_branch: 'main' }));
markStep('up-f6', 'workflow_init', 'complete');
writeState('nocwd-f6', createInitialState('nocwd-f6', {}));
markStep('nocwd-f6', 'workflow_init', 'complete');
" >/dev/null 2>&1
    from() {
        env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="heir-f6" \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            CLAUDE_TRANSCRIPT_BASE_DIR="$tmp/transcripts" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 60 node "$CLI" --from "$1" 2>&1
    }
    out="$(from up-f6)"
    case "$out" in *FEAT2218-TAIL-TOKEN*|*FEAT2218-UPSTREAM-TOKEN*) problems="$problems raw-transcript-text-leaked-into-stdout" ;; *) : ;; esac
    verdict=$(env -u CLAUDE_SESSION_ID OUT="$out" "$RWT" 30 node -e "
const problems = [];
let j = null;
try { j = JSON.parse(process.env.OUT); } catch (e) { problems.push('stdout-not-json'); }
if (j) {
  const t = j.transcript_tail || (j.upstream && j.upstream.transcript_tail);
  if (!t) problems.push('no-transcript_tail');
  else {
    if (t.available !== true) problems.push('available:' + String(t.available));
    if (typeof t.path !== 'string' || t.path.length === 0) problems.push('path:' + JSON.stringify(t.path));
    if (t.upstreamSid !== 'up-f6') problems.push('upstreamSid:' + String(t.upstreamSid));
    for (const k of Object.keys(t)) {
      if (['available', 'path', 'upstreamSid', 'reason', 'bytes', 'size'].indexOf(k) === -1) problems.push('unexpected-field:' + k);
      if (k === 'text' || k === 'tail' || k === 'content') problems.push('raw-text-field-present:' + k);
    }
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$verdict" = "OK" ] || problems="$problems shape:'$verdict'"
    out="$(from nocwd-f6)"
    case "$out" in *'"available":false'*|*'"available": false'*) : ;; *) problems="$problems available-not-false-without-a-recorded-cwd:'${out:0:200}'" ;; esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F6: transcript_tail carries only a path, never raw text, and available tracks the recorded upstream cwd"
    else
        fail "F6: —$problems"
    fi
}

# F7 — finding 8 (round 3): F4-F6 build fixtures with session-title.js's
# _encodeCwd (which resolves cwd first), while upstream-search.sh's fixture and
# candidates.js's transcriptDirFor encode the raw string with no resolve step.
# On a Windows POSIX drive-letter cwd the two disagree, so `--from` and `--list`
# would resolve to different transcript directories for the same session. This
# pins the two encoders as one contract until the duplication is unified.
run_F7() {
    local out problems
    problems=""
    out=$(env -u CLAUDE_SESSION_ID "$RWT" 30 node -e "
const path = require('path');
const { _encodeCwd } = require('$AGENTS_DIR_NODE/hooks/lib/session-title');
const { transcriptDirFor } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/candidates');
const problems = [];
for (const cwd of ['/home/user/project', 'C:\\\\Users\\\\dev\\\\repo']) {
  const left = _encodeCwd(cwd);
  const right = path.basename(transcriptDirFor(cwd));
  if (left !== right) problems.push('mismatch:' + JSON.stringify(cwd) + ':_encodeCwd=' + left + ':transcriptDirFor=' + right);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    [ "$out" = "OK" ] || problems="$problems $out"
    if [ -z "$problems" ]; then
        pass "F7: session-title.js's _encodeCwd and candidates.js's transcriptDirFor agree on an absolute POSIX cwd and a drive-letter cwd"
    else
        fail "F7: the two cwd encoders disagree —$problems"
    fi
}

run_F1
run_F2
run_F3
run_F4
run_F5
run_F6
run_F7

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
