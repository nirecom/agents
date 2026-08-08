# shellcheck shell=bash
# helpers/inheritance.sh
# Tests: hooks/session-start.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/lifecycle.js, hooks/supervisor-guard/detect.js
# Tags: session-inherit, provenance, regression-1794, scope:issue-specific, pwsh-not-required, TL2
#
# Session-inheritance fixtures for the #1794 adoption
# (I) cases. Split out of helpers.sh to keep both files under the 300-line WARN
# threshold (rules/coding/file-split.md Pattern A). Sourced by helpers.sh.
# Expects AGENTS_DIR, RWT, STATEIO_NODE, make_tmp and node_path.

# ── #1794 adoption fixtures (I cases) ───────────────────────────────────────
# These build a REAL inherited session: a donor state, a transcript that
# announces it, and an heir created by launching hooks/session-start.js itself,
# so every inherited step_status carries provenance:"backfilled" and
# origin:"session-inherit" exactly as a live SessionStart would write it.
# Layout under <tmp>: wf/ (dual-pinned workflow AND plans dir), repo/ (fixture
# git repo), tr/ (transcript base), home/ (temp HOME), cfg/ (fixture config).

SESSION_START_HOOK="$AGENTS_DIR/hooks/session-start.js"

# mk_fixture_repo <dir> — a real one-commit git repo with hooks disabled, so the
# git calls inside getCurrentContext()/resolveRepoDir resolve a throwaway
# fixture instead of the developer's worktree.
mk_fixture_repo() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    git -C "$dir" init -q >/dev/null 2>&1 || return 1
    git -C "$dir" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$dir" config user.email "fixture@example.com" >/dev/null 2>&1
    git -C "$dir" config user.name "1794 fixture" >/dev/null 2>&1
    git -C "$dir" config commit.gpgsign false >/dev/null 2>&1
    printf 'fixture\n' > "$dir/README.md"
    git -C "$dir" add README.md >/dev/null 2>&1 || return 1
    git -C "$dir" commit -q --no-verify -m fixture >/dev/null 2>&1 || return 1
}

# inh_node <tmp> <js|--hook> [sid] — one node launch under the full isolation
# contract (dual-pinned CLAUDE_WORKFLOW_DIR + WORKFLOW_PLANS_DIR, temp HOME,
# fixture AGENTS_CONFIG_DIR / CLAUDE_PROJECT_DIR / CLAUDE_TRANSCRIPT_BASE_DIR,
# inherited session ids unset), run from the fixture repo. `--hook` form pipes a
# SessionStart payload for <sid> into the real hooks/session-start.js. Sets INH_OUT.
inh_node() {
    local tmp="$1" js="$2" sid="${3:-}" wfn homn
    wfn="$(node_path "$tmp/wf")"; homn="$(node_path "$tmp/home")"
    if [ "$js" = "--hook" ]; then
        INH_OUT=$(cd "$tmp/repo" && printf '{"session_id":"%s"}' "$sid" | env \
            -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            CLAUDE_WORKFLOW_DIR="$wfn" WORKFLOW_PLANS_DIR="$wfn" \
            CLAUDE_TRANSCRIPT_BASE_DIR="$(node_path "$tmp/tr")" \
            CLAUDE_PROJECT_DIR="$(node_path "$tmp/repo")" \
            AGENTS_CONFIG_DIR="$(node_path "$tmp/cfg")" \
            HOME="$tmp/home" USERPROFILE="$homn" \
            "$RWT" 60 node "$(node_path "$SESSION_START_HOOK")" 2>&1)
        return $?
    fi
    INH_OUT=$(cd "$tmp/repo" && env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$wfn" WORKFLOW_PLANS_DIR="$wfn" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$(node_path "$tmp/tr")" \
        CLAUDE_PROJECT_DIR="$(node_path "$tmp/repo")" \
        AGENTS_CONFIG_DIR="$(node_path "$tmp/cfg")" \
        HOME="$tmp/home" USERPROFILE="$homn" \
        "$RWT" 60 node -e "$js" 2>&1)
}

# seed_donor_and_inherit <tmp> <donor> <heir> <ci-mode>
# Builds the whole inheritance fixture and creates <heir> through the REAL
# SessionStart hook (which also spawns bin/workflow/next-step as a child — the
# path I8 targets). <ci-mode>:
#   complete — donor finished clarify_intent. Its <donor>-intent.md MUST exist,
#              or evaluateInheritance's S3 rule stops the whole donor scan and
#              nothing is inherited at all.
#   pending  — donor left clarify_intent pending, and <heir>-intent.md is planted
#              up front so the heir's own next-step run resolves it from evidence
#              (the C1 path). See the closes_issues note at the bottom of the body.
# Sets INH_OUT (session-start stdout+stderr).
seed_donor_and_inherit() {
    local tmp="$1" donor="$2" heir="$3" mode="$4" enc
    mkdir -p "$tmp/wf" "$tmp/tr" "$tmp/home" "$tmp/cfg"
    printf '# fixture config for tests/feature-1794-stop-guard-exemptions\nAGENT_FIXTURE=1\n' > "$tmp/cfg/.env"
    mk_fixture_repo "$tmp/repo" || return 1
    enc=$(cd "$tmp/repo" && node -e 'console.log(require("path").resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,"-"))' 2>/dev/null)
    [ -n "$enc" ] || return 1
    mkdir -p "$tmp/tr/$enc"
    printf '{"type":"attachment","attachment":{"hookEvent":"SessionStart","exitCode":0,"stdout":"Current workflow session_id: %s"}}\n' \
        "$donor" > "$tmp/tr/$enc/$donor.jsonl"
    if [ "$mode" = "complete" ]; then printf '# fixture intent\n' > "$tmp/wf/$donor-intent.md"
    else printf '# fixture intent\n' > "$tmp/wf/$heir-intent.md"; fi
    inh_node "$tmp" "
const S = require('$STATEIO_NODE');
const sid = '$donor';
S.writeState(sid, S.createInitialState(sid, S.getCurrentContext()));
S.markStep(sid, 'workflow_init', 'complete');
if ('$mode' === 'complete') S.markStep(sid, 'clarify_intent', 'complete');
" || return 1
    inh_node "$tmp" --hook "$heir"
    [ "$mode" = "complete" ] && return 0

    # closes_issues is a FACT ABOUT THE DONOR SESSION and is deliberately not
    # inherited (hooks/session-start.js), while next-step refuses to advance past
    # clarify_intent with an empty closes_issues — so the first SessionStart's
    # next-step child stops at REASON=closes_issues-empty and persistResolutions
    # never runs. Stamping the top-level field settles no step and appends no
    # step_status event; the SECOND SessionStart below then reaches the evidence
    # resolution for real. session-start skips state CREATION when the file
    # already exists but ALWAYS calls buildWorkflowStatus, which spawns the real
    # bin/workflow/next-step — so this is still the hook's own automatic run,
    # with zero user action settling a step.
    inh_node "$tmp" "
require('$STATEIO_NODE').updateTopLevel('$heir', (r) => { r.closes_issues = [1794]; });" || return 1
    inh_node "$tmp" --hook "$heir"
}

# ── shared drivers for the I cases ──────────────────────────────────────────
# These live here (not in a single case file) because three case files now use
# them: i-inherited-adoption.sh, i-guard-robustness.sh and i-adoption-predicate.sh.

# inh_wf <tmp> — the dual-pinned workflow+plans dir of an inheritance fixture.
inh_wf() { node_path "$1/wf"; }

# inh_guard <c4|c2> <tmp> <sid> [transcript] — run_c4 / run_c2 against an
# inheritance fixture, with CLAUDE_PROJECT_DIR and HOME pointed at the fixture for
# the duration so the next-step child the guard spawns resolves the throwaway repo,
# never the real worktree. The prior values are restored afterwards (the runner
# shares one shell). [transcript] is optional and reaches the C1 hang detector.
inh_guard() {
    local which="$1" tmp="$2" sid="$3" tp="${4:-}" _home="$HOME" _up="${USERPROFILE:-}"
    export CLAUDE_PROJECT_DIR="$(node_path "$tmp/repo")"
    export HOME="$tmp/home" USERPROFILE="$(node_path "$tmp/home")"
    if [ "$which" = "c4" ]; then
        run_c4 "$(inh_wf "$tmp")" "$sid" "$tp"
    else
        run_c2 "$(inh_wf "$tmp")" "$sid" "$tp"
    fi
    export HOME="$_home"
    if [ -n "$_up" ]; then export USERPROFILE="$_up"; else unset USERPROFILE; fi
    unset CLAUDE_PROJECT_DIR
}

# inh_probe <tmp> <sid> <js-body> — evaluates <js-body> against the heir with the
# worktree-local lifecycle module in scope as `L` and the raw state as `st`.
# Echoes whatever the body prints. Uses the WORKTREE copy on purpose: assertions
# about this branch's predicate must not read the deployed ~/.claude/ one.
inh_probe() {
    inh_node "$1" "
const L = require('$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js');
const fs = require('fs'), path = require('path');
const sid = '$2';
const st = JSON.parse(fs.readFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + '.json'), 'utf8'));
const started = () => { try { return String(L.isWorkflowStarted(sid)); } catch (e) { return 'THREW:' + e.message; } };
$3"
    printf '%s' "$INH_OUT"
}

# inh_anchor <tmp> <sid> — POSITIVE ANCHOR for the inherited-only shape. Echoes
# ANCHOR_OK only when the heir really did inherit: workflow_init projects
# `complete` AND at least one step_status event exists AND every one of them is
# backfilled/session-inherit. Without this a silently-broken fixture would make
# C4/C2 correctly silent for the WRONG reason (nothing to guard against at all).
inh_anchor() {
    inh_probe "$1" "$2" "
const ss = st.events.filter((e) => e.kind === 'step_status');
const foreign = ss.filter((e) => e.provenance !== 'backfilled' || e.origin !== 'session-inherit')
  .map((e) => e.step + ':' + e.provenance + '/' + e.origin);
const wi = ((st.current || {}).steps || {}).workflow_init || {};
const bad = [];
if (wi.status !== 'complete') bad.push('workflow_init=' + wi.status);
if (ss.length < 1) bad.push('no-step_status-events');
if (foreign.length) bad.push('not-backfilled(' + foreign.join(',') + ')');
console.log(bad.length ? 'ANCHOR_BAD:' + bad.join(' ') : 'ANCHOR_OK');"
}

# write_hang_transcript <path> — a JSONL transcript whose LAST assistant turn ends
# with a MARK_STEP Bash tool_use and no tool_use after it, i.e. the exact shape
# hooks/supervisor-guard/detect.js detectSentinelHang() calls a C1 hang. Same
# fixture shape as tests/feature-719-supervisor-guard-hook G11.
write_hang_transcript() {
    {
        printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\""}}]}}'
    } > "$1"
}

# seed_recording_only <tmp> <sid> — a session whose stream carries ONLY
# non-step_status records (session_model + complexity_evaluation). Nothing here
# settles a step, so an implementation that asks "any non-backfilled event?"
# instead of "a self-recorded step settlement?" answers wrongly.
seed_recording_only() {
    local tmp="$1" sid="$2"
    mkdir -p "$tmp/wf" "$tmp/home"
    CLAUDE_WORKFLOW_DIR="$(node_path "$tmp/wf")" WORKFLOW_PLANS_DIR="$(node_path "$tmp/wf")" \
    HOME="$tmp/home" USERPROFILE="$(node_path "$tmp/home")" "$RWT" 20 node -e "
const S = require('$STATEIO_NODE');
S.writeState('$sid', S.createInitialState('$sid', { cwd: process.cwd(), git_branch: null }));
S.recordSessionModel('$sid', { id: 'claude-opus-5', source: 'transcript' });
S.recordComplexityEvaluation('$sid', 'high', ['S1-multi-file']);" >/dev/null 2>&1
}
