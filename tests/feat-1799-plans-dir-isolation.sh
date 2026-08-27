#!/usr/bin/env bash
# tests/feat-1799-plans-dir-isolation.sh
# Tests: hooks/lib/load-env.js, hooks/lib/supervisor-emit.js, bin/check-plans-dir-isolation.sh
# Tags: supervisor-emit, isolation, plans-dir, xor-guard, scope:issue-specific, pwsh-not-required, TL2
# #1799: a suite pinning CLAUDE_WORKFLOW_DIR but NOT WORKFLOW_PLANS_DIR drives the real hooks,
# and supervisor-emit.js appends escape_hatch_event findings into the developer's LIVE
# ~/.workflow-plans state. The fix is an XOR guard at supervisor-emit.js#safeAppend: both
# pinned (isolated test) or neither (production) → write; exactly one → refuse, no write.
# It must read the PRISTINE process-start snapshot (load-env.js#getPristineIsolationEnv),
# never live process.env, since loadDefaultEnv() injects WORKFLOW_PLANS_DIR from .env (G6).
# TL2 gap: in-process require, not a real `claude -p` dispatch — see rules/test/fixture-isolation.md.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
EMIT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-emit.js"
LOADENV_NODE="$_AGENTS_DIR_NODE/hooks/lib/load-env.js"
CLASSIFIER="$AGENTS_DIR/bin/check-plans-dir-isolation.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'iso1799')"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

SID="s1799iso"

# ── Fixture builders ────────────────────────────────────────────────────────
# Every case gets its own sandbox: a pinned plans dir, a decoy "real" plans dir
# reachable only via HOME/USERPROFILE, and an empty AGENTS_CONFIG_DIR so that
# loadDefaultEnv() can never reach the real repo .env and inject a live path.
# (os.homedir() reads USERPROFILE on win32 and HOME elsewhere — both are set.)
new_sandbox() {  # <tag> → echoes "<pinned>|<decoyhome>|<cfgdir>"
    local root="$TMPDIR_BASE/$1"
    mkdir -p "$root/pinned" "$root/home/.workflow-plans" "$root/cfg"
    printf '%s|%s|%s' "$root/pinned" "$root/home" "$root/cfg"
}

# Count *-supervisor-state.json files under a dir.
count_states() { find "$1" -name '*-supervisor-state.json' 2>/dev/null | wc -l | tr -d ' '; }

# emit_call <js-body> — the snippet run inside the emit process.
EMIT_SENTINEL="const em=require('$EMIT_NODE'); em.reportSentinel('WORKFLOW_OFF','G-case reason','$SID');"

# run_emit <pinned-or-empty> <plansvar-or-UNSET> <wfdirvar-or-UNSET> <home> <cfg> <js>
# Sets/unsets the two isolation vars precisely, then runs the snippet.
# Echoes stderr; stdout of the snippet is discarded.
run_emit() {
    local plansval="$1" wfval="$2" home="$3" cfg="$4" js="$5"
    # env(1) requires all options before any NAME=VALUE assignment.
    local -a unsets=() assigns=()
    assigns+=("HOME=$home" "USERPROFILE=$home" "AGENTS_CONFIG_DIR=$cfg")
    if [ "$plansval" = "UNSET" ]; then unsets+=("-u" "WORKFLOW_PLANS_DIR"); else assigns+=("WORKFLOW_PLANS_DIR=$plansval"); fi
    if [ "$wfval" = "UNSET" ]; then unsets+=("-u" "CLAUDE_WORKFLOW_DIR"); else assigns+=("CLAUDE_WORKFLOW_DIR=$wfval"); fi
    env ${unsets[@]+"${unsets[@]}"} "${assigns[@]}" "$RWT" 15 node -e "$js" 2>&1 >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# G1 — both pinned: write lands in the pinned dir, decoy "real" dir stays clean.
# ─────────────────────────────────────────────────────────────────────────────
G1_both_pinned_writes_to_pinned_dir() {
    local pinned home cfg pn err
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g1)"
    pn="$(node_path "$pinned")"
    err="$(run_emit "$pn" "$pn" "$home" "$cfg" "$EMIT_SENTINEL")"

    if [ -f "$pinned/$SID-supervisor-state.json" ]; then
        pass "G1a both pinned → finding written to the pinned plans dir"
    else
        fail "G1a both pinned → no state file in pinned dir (stderr=$err)"
    fi
    if [ "$(count_states "$home/.workflow-plans")" = "0" ]; then
        pass "G1b both pinned → decoy real plans dir untouched (isolation proven)"
    else
        fail "G1b both pinned → decoy real plans dir was written to: $(ls "$home/.workflow-plans")"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G2 — CLAUDE_WORKFLOW_DIR only: refuse, name the MISSING var, write nothing.
# ─────────────────────────────────────────────────────────────────────────────
G2_wfdir_only_refuses() {
    local pinned home cfg pn err
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g2)"
    pn="$(node_path "$pinned")"
    err="$(run_emit "UNSET" "$pn" "$home" "$cfg" "$EMIT_SENTINEL")"

    if [ "$(count_states "$pinned")" = "0" ] && [ "$(count_states "$home/.workflow-plans")" = "0" ]; then
        pass "G2a CLAUDE_WORKFLOW_DIR-only → nothing written anywhere"
    else
        fail "G2a CLAUDE_WORKFLOW_DIR-only wrote a state file (pinned=$(count_states "$pinned") home=$(count_states "$home/.workflow-plans"))"
    fi
    if echo "$err" | grep -q 'WORKFLOW_PLANS_DIR unset'; then
        pass "G2b refusal diagnostic names WORKFLOW_PLANS_DIR as the unset half"
    else
        fail "G2b refusal diagnostic missing/does not name WORKFLOW_PLANS_DIR as unset: '$err'"
    fi
    # The diagnostic must print variable NAMES only — plans paths embed the OS username
    # and this text can land in a transcript.
    if ! echo "$err" | grep -qF "$pinned"; then
        pass "G2c refusal diagnostic leaks no path value"
    else
        fail "G2c refusal diagnostic leaked the plans dir path: '$err'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G3 — WORKFLOW_PLANS_DIR only: the symmetric arm must be treated identically (CPR-ORTH).
# ─────────────────────────────────────────────────────────────────────────────
G3_plansdir_only_refuses() {
    local pinned home cfg pn err
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g3)"
    pn="$(node_path "$pinned")"
    err="$(run_emit "$pn" "UNSET" "$home" "$cfg" "$EMIT_SENTINEL")"

    if [ "$(count_states "$pinned")" = "0" ] && [ "$(count_states "$home/.workflow-plans")" = "0" ]; then
        pass "G3a WORKFLOW_PLANS_DIR-only → nothing written anywhere"
    else
        fail "G3a WORKFLOW_PLANS_DIR-only wrote a state file (pinned=$(count_states "$pinned"))"
    fi
    if echo "$err" | grep -q 'CLAUDE_WORKFLOW_DIR unset'; then
        pass "G3b symmetric refusal names CLAUDE_WORKFLOW_DIR as the unset half"
    else
        fail "G3b symmetric refusal missing/does not name CLAUDE_WORKFLOW_DIR as unset: '$err'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G4 — neither pinned: production path, fail-open write must still happen.
# ─────────────────────────────────────────────────────────────────────────────
G4_neither_pinned_writes() {
    local pinned home cfg err
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g4)"
    err="$(run_emit "UNSET" "UNSET" "$home" "$cfg" "$EMIT_SENTINEL")"

    if [ -f "$home/.workflow-plans/$SID-supervisor-state.json" ]; then
        pass "G4a neither pinned → write succeeds (fail-open preserved)"
    else
        fail "G4a neither pinned → write was suppressed; guard must not fire (stderr=$err)"
    fi
    if [ -z "$(echo "$err" | grep -i 'isolation contradiction')" ]; then
        pass "G4b neither pinned → no refusal diagnostic emitted"
    else
        fail "G4b neither pinned emitted a refusal diagnostic: '$err'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G5 — empty string is "unset", not "set". Windows propagates VAR="" into children,
#      so a naive `in process.env` / `!== undefined` check misclassifies it.
# ─────────────────────────────────────────────────────────────────────────────
G5_empty_string_is_unset() {
    local pinned home cfg pn err
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g5a)"
    # (a) CLAUDE_WORKFLOW_DIR="" + WORKFLOW_PLANS_DIR unset → BOTH unset → write.
    err="$(run_emit "UNSET" "" "$home" "$cfg" "$EMIT_SENTINEL")"
    if [ -f "$home/.workflow-plans/$SID-supervisor-state.json" ]; then
        pass "G5a CLAUDE_WORKFLOW_DIR=\"\" counts as unset → both-unset → write succeeds"
    else
        fail "G5a empty CLAUDE_WORKFLOW_DIR was counted as set → false refusal (stderr=$err)"
    fi

    # (b) CLAUDE_WORKFLOW_DIR="" + WORKFLOW_PLANS_DIR pinned → still XOR → refuse.
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g5b)"
    pn="$(node_path "$pinned")"
    err="$(run_emit "$pn" "" "$home" "$cfg" "$EMIT_SENTINEL")"
    if [ "$(count_states "$pinned")" = "0" ] && echo "$err" | grep -q 'CLAUDE_WORKFLOW_DIR unset'; then
        pass "G5b CLAUDE_WORKFLOW_DIR=\"\" + pinned plans dir → still a contradiction → refused"
    else
        fail "G5b empty-string half must still count as unset (files=$(count_states "$pinned") stderr='$err')"
    fi

    # (c) WORKFLOW_PLANS_DIR="" + CLAUDE_WORKFLOW_DIR unset → BOTH unset → write (CPR-ORTH symmetric).
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g5c)"
    err="$(run_emit "" "UNSET" "$home" "$cfg" "$EMIT_SENTINEL")"
    if [ -f "$home/.workflow-plans/$SID-supervisor-state.json" ]; then
        pass "G5c WORKFLOW_PLANS_DIR=\"\" counts as unset → both-unset → write succeeds (CPR-ORTH)"
    else
        fail "G5c empty WORKFLOW_PLANS_DIR was counted as set → false refusal (stderr=$err)"
    fi

    # (d) WORKFLOW_PLANS_DIR="" + CLAUDE_WORKFLOW_DIR pinned → still XOR → refuse (CPR-ORTH symmetric).
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g5d)"
    pn="$(node_path "$pinned")"
    err="$(run_emit "" "$pn" "$home" "$cfg" "$EMIT_SENTINEL")"
    if [ "$(count_states "$pinned")" = "0" ] && echo "$err" | grep -q 'WORKFLOW_PLANS_DIR unset'; then
        pass "G5d WORKFLOW_PLANS_DIR=\"\" + pinned wfdir → contradiction → refused (CPR-ORTH)"
    else
        fail "G5d empty WORKFLOW_PLANS_DIR half must still be unset (files=$(count_states "$pinned") stderr='$err')"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G6 — .env injection. AGENTS_CONFIG_DIR/.env supplies WORKFLOW_PLANS_DIR; neither var is
#      exported by the caller. The pristine snapshot is empty on both axes → both-unset →
#      write succeeds. A guard reading live process.env sees PLANS set / WFDIR unset and
#      wrongly refuses. This is the case a naive implementation fails.
# ─────────────────────────────────────────────────────────────────────────────
G6_env_injection_uses_pristine_snapshot() {
    local root envplans cfg home err
    root="$TMPDIR_BASE/g6"
    envplans="$root/env-supplied-plans"
    cfg="$root/cfg"
    home="$root/home"
    mkdir -p "$envplans" "$cfg" "$home/.workflow-plans"
    printf 'WORKFLOW_PLANS_DIR=%s\n' "$(node_path "$envplans")" > "$cfg/.env"

    err="$(run_emit "UNSET" "UNSET" "$home" "$cfg" "$EMIT_SENTINEL")"

    if [ -f "$envplans/$SID-supervisor-state.json" ]; then
        pass "G6a .env-injected WORKFLOW_PLANS_DIR does not trip the guard (pristine snapshot read)"
    else
        fail "G6a write suppressed or misrouted: guard appears to read post-injection process.env (stderr=$err)"
    fi
    if ! echo "$err" | grep -qi 'isolation contradiction'; then
        pass "G6b no refusal diagnostic for the .env injection case"
    else
        fail "G6b guard refused on .env injection — it is reading live process.env, not the snapshot: '$err'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G6c — getPristineIsolationEnv() is exported, frozen, and normalizes ""/whitespace to null.
# ─────────────────────────────────────────────────────────────────────────────
G6c_pristine_api_shape() {
    local root cfg out
    root="$TMPDIR_BASE/g6c"; cfg="$root/cfg"; mkdir -p "$cfg"
    # CLAUDE_WORKFLOW_DIR="   " (whitespace-only) — must normalize to null.
    out="$(env -u WORKFLOW_PLANS_DIR "AGENTS_CONFIG_DIR=$cfg" "CLAUDE_WORKFLOW_DIR=   " \
        "$RWT" 15 node -e "
const m = require('$LOADENV_NODE');
if (typeof m.getPristineIsolationEnv !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const a = m.getPristineIsolationEnv();
const frozen = Object.isFrozen(a);
const ws = a.CLAUDE_WORKFLOW_DIR === null;
const unset = a.WORKFLOW_PLANS_DIR === null;
process.stdout.write((frozen?'F':'f') + (ws?'W':'w') + (unset?'U':'u'));
" 2>/dev/null)"
    if [ "$out" = "FWU" ]; then
        pass "G6c(wf) getPristineIsolationEnv() exported, frozen, normalizes blank CLAUDE_WORKFLOW_DIR → null"
    else
        fail "G6c(wf) getPristineIsolationEnv() shape wrong (want FWU), got '${out:-<err>}'"
    fi

    # WORKFLOW_PLANS_DIR="   " (whitespace-only) — must normalize to null (CPR-ORTH symmetric).
    root="$TMPDIR_BASE/g6c2"; cfg="$root/cfg"; mkdir -p "$cfg"
    out="$(env -u CLAUDE_WORKFLOW_DIR "AGENTS_CONFIG_DIR=$cfg" "WORKFLOW_PLANS_DIR=   " \
        "$RWT" 15 node -e "
const m = require('$LOADENV_NODE');
if (typeof m.getPristineIsolationEnv !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const a = m.getPristineIsolationEnv();
const frozen = Object.isFrozen(a);
const unset_wf = a.CLAUDE_WORKFLOW_DIR === null;
const ws = a.WORKFLOW_PLANS_DIR === null;
process.stdout.write((frozen?'F':'f') + (unset_wf?'U':'u') + (ws?'W':'w'));
" 2>/dev/null)"
    if [ "$out" = "FUW" ]; then
        pass "G6c(plans) getPristineIsolationEnv() normalizes blank WORKFLOW_PLANS_DIR → null (CPR-ORTH)"
    else
        fail "G6c(plans) getPristineIsolationEnv() shape wrong (want FUW), got '${out:-<err>}'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G7 — at most one diagnostic per process: hook stdout/stderr is parsed by the harness,
#      and a hook that calls report* in a loop must not flood it.
# ─────────────────────────────────────────────────────────────────────────────
G7_diagnostic_once_per_process() {
    local pinned home cfg pn err n
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g7)"
    pn="$(node_path "$pinned")"
    err="$(run_emit "UNSET" "$pn" "$home" "$cfg" "
const em=require('$EMIT_NODE');
em.reportSentinel('WORKFLOW_OFF','first','$SID');
em.reportSentinel('WORKTREE_OFF','second','$SID');
em.reportBlock('enforce-worktree','git commit','$SID');
em.reportFallback('worktree-end','notes','$SID');
")"
    n="$(echo "$err" | grep -ci 'isolation contradiction')"
    if [ "$n" = "1" ]; then
        pass "G7 four report* calls in one process emit exactly one diagnostic"
    else
        fail "G7 diagnostic emitted $n times (want exactly 1): '$err'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G8 — all four report* entrypoints are covered. They share safeAppend(), so guarding the
#      choke point covers the class structurally (CPR-E2C); this table proves it per member.
# ─────────────────────────────────────────────────────────────────────────────
G8_all_entrypoints_guarded() {
    local name call pinned home cfg pn err
    while IFS='|' read -r name call; do
        [ -z "${name// /}" ] && continue
        name="${name//[[:space:]]/}"
        IFS='|' read -r pinned home cfg <<< "$(new_sandbox "g8-$name")"
        pn="$(node_path "$pinned")"
        err="$(run_emit "UNSET" "$pn" "$home" "$cfg" "const em=require('$EMIT_NODE'); $call")"
        if [ "$(count_states "$pinned")" = "0" ] && [ "$(count_states "$home/.workflow-plans")" = "0" ] \
           && echo "$err" | grep -qi 'isolation contradiction'; then
            pass "G8 $name: XOR state refused, no write"
        else
            fail "G8 $name: not covered by the guard (pinned=$(count_states "$pinned") stderr='$err')"
        fi
    done <<TABLE
reportSentinel      | em.reportSentinel('WORKFLOW_OFF','g8 reason','$SID');
reportBlock         | em.reportBlock('enforce-worktree','git commit -m x','$SID');
reportFallback      | em.reportFallback('worktree-end','WORKTREE_NOTES fallback','$SID');
reportRetrospective | em.reportRetrospective('g8 observation','$SID');
TABLE
}

# ─────────────────────────────────────────────────────────────────────────────
# G8e — the guard must not convert a refusal into a thrown error. The fail-open contract
#       (every export returns void on failure) is what keeps hooks from crashing.
# ─────────────────────────────────────────────────────────────────────────────
G8e_guard_never_throws() {
    local pinned home cfg pn out
    IFS='|' read -r pinned home cfg <<< "$(new_sandbox g8e)"
    pn="$(node_path "$pinned")"
    out="$(env -u WORKFLOW_PLANS_DIR "HOME=$home" "USERPROFILE=$home" "AGENTS_CONFIG_DIR=$cfg" \
        "CLAUDE_WORKFLOW_DIR=$pn" \
        "$RWT" 15 node -e "
const em=require('$EMIT_NODE');
try { em.reportSentinel('WORKFLOW_OFF','g8e','$SID'); process.stdout.write('NOTHROW'); }
catch (e) { process.stdout.write('THREW'); }
" 2>/dev/null)"
    if [ "$out" = "NOTHROW" ]; then
        pass "G8e refusal returns void — fail-open contract intact (no throw)"
    else
        fail "G8e guard threw instead of returning void: '${out:-<err>}'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G8f — isolationContradiction() is exported so tests and tooling can evaluate the rule
#       without booting a hook.
# ─────────────────────────────────────────────────────────────────────────────
G8f_isolation_contradiction_exported() {
    local root cfg both neither xor1 xor2
    root="$TMPDIR_BASE/g8f"; cfg="$root/cfg"; mkdir -p "$cfg" "$root/p"
    local pn; pn="$(node_path "$root/p")"
    local probe="const em=require('$EMIT_NODE');
if (typeof em.isolationContradiction !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
process.stdout.write(String(em.isolationContradiction()));"

    both="$(env "AGENTS_CONFIG_DIR=$cfg" "CLAUDE_WORKFLOW_DIR=$pn" "WORKFLOW_PLANS_DIR=$pn" "$RWT" 15 node -e "$probe" 2>/dev/null)"
    neither="$(env -u CLAUDE_WORKFLOW_DIR -u WORKFLOW_PLANS_DIR "AGENTS_CONFIG_DIR=$cfg" "$RWT" 15 node -e "$probe" 2>/dev/null)"
    xor1="$(env -u WORKFLOW_PLANS_DIR "AGENTS_CONFIG_DIR=$cfg" "CLAUDE_WORKFLOW_DIR=$pn" "$RWT" 15 node -e "$probe" 2>/dev/null)"
    xor2="$(env -u CLAUDE_WORKFLOW_DIR "AGENTS_CONFIG_DIR=$cfg" "WORKFLOW_PLANS_DIR=$pn" "$RWT" 15 node -e "$probe" 2>/dev/null)"

    if [ "$both:$neither:$xor1:$xor2" = "false:false:true:true" ]; then
        pass "G8f isolationContradiction() truth table: both=false neither=false xor=true"
    else
        fail "G8f isolationContradiction() truth table wrong: both=$both neither=$neither xor1=$xor1 xor2=$xor2 (want false:false:true:true)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# G9 — bin/check-plans-dir-isolation.sh, the static audit classifier.
#      Report-only tool: always exit 0, never a gate. The two files below are the
#      pre-verified disputed pair from the audit manifest.
# ─────────────────────────────────────────────────────────────────────────────
G9_classifier_verdicts() {
    if [ ! -f "$CLASSIFIER" ]; then
        fail "G9 classifier: $CLASSIFIER does not exist"
        fail "G9b classifier W-candidate for feature-workflow-off-chain-guard.sh (blocked: no classifier)"
        fail "G9c classifier N-candidate for feature-workflow-off-bypass-block-history-direct.sh (blocked: no classifier)"
        fail "G9d classifier sweep-complete regression guard (blocked: no classifier)"
        return
    fi

    local out rc

    # G9a/G9c use a FIXTURE N-candidate for the same reason G9b uses one: this fix
    # dual-pinned every live repo test, so no production file is a candidate any more.
    # The fixture pins CLAUDE_WORKFLOW_DIR, omits WORKFLOW_PLANS_DIR, and reaches only a
    # read-only hook — exactly the shape the classifier must call N rather than W.
    local n_fixture_dir n_fixture
    n_fixture_dir="$TMPDIR_BASE/g9c-fixture"
    n_fixture="$n_fixture_dir/feature-readonly-halfpinned-suite.sh"
    mkdir -p "$n_fixture_dir"
    printf '#!/usr/bin/env bash\n# Tests: hooks/block-history-direct.js\nCLAUDE_WORKFLOW_DIR=/tmp/pin node hooks/block-history-direct.js\n' > "$n_fixture"

    # G9a — classifier exits 0 even while reporting a candidate (report tool, not a gate).
    out="$(cd "$AGENTS_DIR" && "$RWT" 60 bash "$CLASSIFIER" "$n_fixture" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "G9a classifier exits 0 (report tool, not a gate)"
    else
        fail "G9a classifier exited $rc, must always be 0: $out"
    fi

    # G9b — classifier recognises a W-candidate from a FIXTURE file (not a live repo file,
    # because all live tests have been dual-pinned as part of this fix making them not W).
    # The fixture simulates an unfixed test that pins CLAUDE_WORKFLOW_DIR, references
    # workflow-gate.js, but has no WORKFLOW_PLANS_DIR pin.
    local fixture_dir fixture_file
    fixture_dir="$TMPDIR_BASE/g9b-fixture"
    fixture_file="$fixture_dir/feature-unfixed-suite.sh"
    mkdir -p "$fixture_dir"
    printf '#!/usr/bin/env bash\n# Tests: hooks/workflow-gate.js\nCLAUDE_WORKFLOW_DIR=/tmp/pin node hooks/workflow-gate.js\n' > "$fixture_file"
    local fixture_rel; fixture_rel="$(cd "$AGENTS_DIR" && realpath --relative-to=. "$fixture_file" 2>/dev/null || echo "$fixture_file")"
    out="$(cd "$AGENTS_DIR" && "$RWT" 60 bash "$CLASSIFIER" "$fixture_file" 2>&1)"
    if echo "$out" | grep -q 'W-candidate'; then
        pass "G9b classifier correctly identifies a fixture unfixed suite as W-candidate (CLAUDE_WORKFLOW_DIR pinned, no WORKFLOW_PLANS_DIR, calls workflow-gate.js)"
    else
        fail "G9b fixture unfixed suite must be W-candidate: $out"
    fi

    # G9c — the fixture launches only hooks/block-history-direct.js, which READS the plans dir
    # (helpers.js tryResolveEnvUnderPlansDir) but never calls appendFinding → N-candidate.
    out="$(cd "$AGENTS_DIR" && "$RWT" 60 bash "$CLASSIFIER" "$n_fixture" 2>&1)"
    if echo "$out" | grep -F "$(basename "$n_fixture")" | grep -q 'N-candidate'; then
        pass "G9c fixture read-only half-pinned suite classified N-candidate (no supervisor write)"
    else
        fail "G9c fixture read-only half-pinned suite must be N-candidate: $out"
    fi

    # Regression guard: once the sweep is done, every W file carries the pin and therefore
    # drops out of the candidate population entirely. A non-empty W-candidate list means the
    # audit has rotted — a new or reverted suite is contaminating the live plans dir again.
    local full wcount
    full="$(cd "$AGENTS_DIR" && "$RWT" 120 bash "$CLASSIFIER" 2>&1)"
    wcount="$(echo "$full" | grep -c 'W-candidate')"
    if [ "$wcount" = "0" ]; then
        pass "G9d repo-wide sweep complete: zero W-candidate files remain unpinned"
    else
        fail "G9d $wcount file(s) reach supervisor-emit with CLAUDE_WORKFLOW_DIR pinned but WORKFLOW_PLANS_DIR unpinned:"$'\n'"$(echo "$full" | grep 'W-candidate')"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

G1_both_pinned_writes_to_pinned_dir
G2_wfdir_only_refuses
G3_plansdir_only_refuses
G4_neither_pinned_writes
G5_empty_string_is_unset
G6_env_injection_uses_pristine_snapshot
G6c_pristine_api_shape
G7_diagnostic_once_per_process
G8_all_entrypoints_guarded
G8e_guard_never_throws
G8f_isolation_contradiction_exported
G9_classifier_verdicts

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
