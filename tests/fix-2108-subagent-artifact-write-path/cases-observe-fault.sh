#!/usr/bin/env bash
# Tests: hooks/lib/protected-basenames.js, hooks/lib/active-session-ids.js, hooks/block-clearance-token-write.js
# Tags: active-session-ids, protected-basename, fail-closed, fault-injection, structured-editor, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).
# Section C15 — observeActiveSessionIds() faulted AT the line that consumes it
# (protected-basenames.js `const { sids, complete } = ...`). C12-4/C12-4b fault the layers
# below it and reach the predicate only through active-session-ids.js's own error handling;
# this section replaces the function itself, driving `complete` — the switch between
# "narrow to the observed sids" and "pre-#2108 suffix-only breadth" — directly.
OF_WF=""
OF_TGT_FWD=""
OF_TGT_SH=""
OF_CFG=""
OF_CWD=""
OF_PRELOAD_SH=""
OF_PRELOAD_NODE=""

# Seeded into a live session's marker before a forged write is attempted (C15-3).
OF_GENUINE="GENUINE-OBSERVE-FAULT-BODY"

_of_write_probes() {
    cat > "$PROBE_DIR/of-observe-fault-preload.js" <<'PROBE_EOF'
"use strict";
// `node -r THIS`: replaces observeActiveSessionIds() in the require cache BEFORE
// protected-basenames.js destructures it at module load. That destructuring is why the
// swap must happen in a preload: once protected-basenames.js holds the function value,
// no later assignment to active-session-ids.js's exports can reach it.
// env: OF_MODULE (absolute path to hooks/lib/active-session-ids.js), OF_FAULT_MODE.
const p = require.resolve(process.env.OF_MODULE);
require(p);
const faults = {
  // The dependency's own DOCUMENTED partial-knowledge answer.
  incomplete: () => ({ sids: new Set(), complete: false }),
  // Contract violations. Each leans a different way, which is the point of pinning them.
  throws: () => { throw new Error("observation exploded"); },
  nullret: () => null,
  nonobj: () => 42,
  nosids: () => ({ complete: true }),
  strsids: () => ({ sids: "not-a-set", complete: true }),
  truthycomplete: () => ({ sids: new Set(), complete: "no" }),
};
const f = faults[process.env.OF_FAULT_MODE || ""];
if (f) {
  require.cache[p].exports = Object.assign({}, require.cache[p].exports, {
    observeActiveSessionIds: f,
  });
}
PROBE_EOF
    cat > "$PROBE_DIR/of-stem-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <protected-basenames.js> <stem> <spelling> -> "true"|"false"|"THREW".
// THREW is a THIRD outcome on purpose: a predicate that throws has not answered
// "protected", and every caller's own error boundary then decides the verdict.
const p = require(process.argv[2]);
try {
  process.stdout.write(String(p.isClearanceBearingStem(process.argv[3], {
    spelling: process.argv[4],
    sessionCtx: { sessionId: "wsid" },
  })));
} catch (_) { process.stdout.write("THREW"); }
PROBE_EOF
}

# _of_probe <mode> <probe-args...>
_of_probe() {
    local mode="$1"; shift
    (
        cd "$OF_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export CLAUDE_WORKFLOW_DIR="$OF_WF" WORKFLOW_PLANS_DIR="$OF_WF"
        export OF_MODULE="$ACTIVE_SIDS_NODE" OF_FAULT_MODE="$mode"
        run_probe -r "$OF_PRELOAD_SH" "$@"
    )
}

# _of_hook <mode> <stdin-json> -> raw block-clearance-token-write stdout
_of_hook() {
    local mode="$1" input="$2"
    (
        cd "$OF_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export AGENTS_CONFIG_DIR="$OF_CFG"
        export CLAUDE_WORKFLOW_DIR="$OF_WF" WORKFLOW_PLANS_DIR="$OF_WF"
        export OF_MODULE="$ACTIVE_SIDS_NODE" OF_FAULT_MODE="$mode"
        # NATIVE preload path: run_hook_capture sets MSYS_NO_PATHCONV=1.
        run_hook_capture "$input" "$RWT" 20 node -r "$OF_PRELOAD_NODE" "$BCTW_HOOK"
    )
}

# _of_decide <mode> <tool> <basename> -> approve | block | crash | timeout
_of_decide() {
    gate_decision "$(_of_hook "$1" "$(mk_edit_input "$2" wsid "$OF_TGT_FWD/$3")")"
}

_of_read() { if [ -e "$1" ]; then cat "$1"; else printf '<absent>'; fi; }

# _of_gated_write <mode> <tool> <basename> <content> -> decision; the tool action is
# really performed on approve, so a negative row can assert the file, not the text.
_of_gated_write() {
    local mode="$1" tool="$2" bn="$3" content="$4" d
    d="$(_of_decide "$mode" "$tool" "$bn")"
    [ "$d" = "approve" ] && printf '%s' "$content" > "$OF_TGT_SH/$bn"
    printf '%s' "$d"
}

_of_setup() {
    local base="$TMPBASE_SH/observe-fault"
    rm -rf "$base" 2>/dev/null || true
    mkdir -p "$base/wf" "$base/target" "$base/config" "$base/cwd"
    OF_WF="$(node_path "$base/wf")"
    OF_CFG="$(node_path "$base/config")"
    OF_TGT_FWD="$(node_path "$base/target")"
    OF_TGT_FWD="${OF_TGT_FWD//\\//}"
    OF_TGT_SH="$base/target"
    OF_CWD="$base/cwd"
    OF_PRELOAD_SH="$PROBE_DIR/of-observe-fault-preload.js"
    OF_PRELOAD_NODE="$(node_path "$PROBE_DIR")/of-observe-fault-preload.js"
    # `wsid` is a REAL entry in the pinned store, so the unfaulted classifier protects
    # `wsid.workflow-off` and allows `issue-2108-survey.gh-env` — the two poles every
    # row below is measured against.
    printf '{"version":1,"session_id":"wsid"}' > "$base/wf/wsid.json"
    _of_write_probes
}

run_C15_observe_fault() {
    local tool

    _of_setup

    # C15-0 — HARNESS CONTROL. The preload is loaded but selects no fault: both poles must
    # read exactly as they do without it, on all three editors. Without this row a broken
    # preload (wrong module path, swap too late) would leave every fault row below
    # measuring the UNfaulted classifier, and passing for the wrong reason.
    for tool in Write Edit MultiEdit; do
        assert_eq "C15-0 control ($tool): a live session's marker is blocked, no fault" "block" \
            "$(_of_decide none "$tool" "wsid.workflow-off")"
        assert_eq "C15-0 control ($tool): the #2108 artifact stem still writes" "approve" \
            "$(_of_decide none "$tool" "issue-2108-survey.gh-env")"
    done
    assert_eq "C15-0 control: the predicate itself is unchanged by the preload" "false" \
        "$(_of_probe none "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" issue-2108-survey clean)"

    # C15-1 — THE REQUIREMENT. `complete:false` is the dependency's documented answer for
    # partial knowledge, and protected-basenames.js turns it into "every stem is
    # clearance-bearing". Asserted on each editor SEPARATELY: Write/Edit/MultiEdit reach
    # the predicate through a different branch of block-clearance-token-write/dispatch.js
    # than Bash does, with a different error boundary, so C12-4b's Bash-only fail-closed
    # row is no evidence at all about the editors (CPR-ORTH).
    for tool in Write Edit MultiEdit; do
        assert_eq "C15-1 $tool: complete:false blocks even an artifact stem (fail-closed)" "block" \
            "$(_of_decide incomplete "$tool" "issue-2108-survey.gh-env")"
        assert_eq "C15-1 $tool: and the live marker stays blocked (no swap of the two)" "block" \
            "$(_of_decide incomplete "$tool" "wsid.workflow-off")"
    done
    assert_eq "C15-1 the Bash route agrees (CPR-ORTH across routes)" "block" \
        "$(gate_decision "$(_of_hook incomplete "$(_c5_cmd "echo x > $OF_TGT_FWD/issue-2108-survey.gh-env")")")"
    assert_eq "C15-1 predicate: complete:false makes the artifact stem bearing (clean)" "true" \
        "$(_of_probe incomplete "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" issue-2108-survey clean)"
    assert_eq "C15-1 predicate: ... and on the bash spelling too" "true" \
        "$(_of_probe incomplete "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" issue-2108-survey bash)"

    # C15-2 — a NON-OBJECT return. Destructuring `42` yields `complete === undefined`,
    # which is falsy, so the same fail-closed branch answers. Pinned because it is the one
    # contract violation that leans SAFE by accident rather than by construction: a future
    # `if (complete === false)` would silently turn it into a fail-open.
    for tool in Write Edit MultiEdit; do
        assert_eq "C15-2 $tool: a non-object observation fails closed" "block" \
            "$(_of_decide nonobj "$tool" "issue-2108-survey.gh-env")"
    done
    assert_eq "C15-2 predicate: a non-object observation is treated as unobservable" "true" \
        "$(_of_probe nonobj "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" issue-2108-survey clean)"

    # C15-3 — PATTERN 1 (protection-fix-tests.md): the rows above read the hook's verdict
    # only. Here the write is really PERFORMED whenever the hook approves, so a guard that
    # says "block" after the bytes have already landed cannot pass.
    printf '%s' "$OF_GENUINE" > "$OF_TGT_SH/wsid.workflow-off"
    assert_eq "C15-3 forged overwrite of a live marker under a faulted observation is blocked" "block" \
        "$(_of_gated_write incomplete Write "wsid.workflow-off" "FORGED-BY-C15")"
    assert_eq "C15-3 the seeded marker survived byte-for-byte" "$OF_GENUINE" \
        "$(_of_read "$OF_TGT_SH/wsid.workflow-off")"
    # HARNESS PROOF: the helper must be ABLE to write, or the row above is false-green.
    assert_eq "C15-3 harness proof: an approved write really lands (unfaulted)" "approve" \
        "$(_of_gated_write none Write "issue-2108-survey.gh-env" "ARTIFACT-BODY-C15")"
    assert_eq "C15-3 harness proof: ... and the bytes are on disk" "ARTIFACT-BODY-C15" \
        "$(_of_read "$OF_TGT_SH/issue-2108-survey.gh-env")"

    _of_characterize_contract_violations
}

# --- CHARACTERIZATION, NOT REQUIREMENT ------------------------------------------------
# The five modes below violate observeActiveSessionIds()'s return contract
# (`{sids: Set, complete: boolean}`, never throwing — it catches internally, pinned by
# C10-1b/C11-1/C11-2), so none of these rows states a requirement. Each records WHICH WAY
# the current code leans when the contract is broken, so a refactor that changes the lean
# shows up as a changed row instead of as silence. Every row reading `approve` is a
# fail-OPEN and is named as such.
_of_characterize_contract_violations() {
    local mode tool

    # C15-4 — a THROWING / null / sids-less observation. The exception escapes
    # isClearanceBearingStem, and the two dispatch branches then disagree: the Bash branch
    # has a fail-closed boundary, the structured-editor branch is fail-OPEN by contract —
    # so a live session's own marker becomes writable through Write/Edit/MultiEdit.
    # This is the SKIPPED note in cases-ghost-sid.sh C12-4b, observed at the consumption
    # point rather than one layer below it, and widened to all three editors.
    # L3 gap: an edit that lets the observation throw re-opens the editor route silently
    # while the Bash route keeps blocking; only a fail-closed catch in the editor branch
    # of block-clearance-token-write/dispatch.js would close it.
    for mode in throws nullret nosids; do
        for tool in Write Edit MultiEdit; do
            assert_eq "C15-4 [$mode] $tool: fail-OPEN characterization — a broken observation approves a live marker" \
                "approve" "$(_of_decide "$mode" "$tool" "wsid.workflow-off")"
        done
        assert_eq "C15-4 [$mode] the Bash route does NOT share that fail-open" "block" \
            "$(gate_decision "$(_of_hook "$mode" "$(_c5_cmd "echo x > $OF_TGT_FWD/wsid.workflow-off")")")"
        assert_eq "C15-4 [$mode] predicate: the exception reaches the caller, unabsorbed" "THREW" \
            "$(_of_probe "$mode" "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" wsid clean)"
    done

    # C15-5 — a MALFORMED `sids` alongside `complete: true`. The worst lean of the five:
    # the clean spelling throws (editor route fail-open) while the bash spelling iterates
    # the string harmlessly and answers FALSE, so BOTH routes approve a live marker.
    # L3 gap: `complete` alone is trusted to certify `sids`; a shape check at the
    # consumption point (`sids instanceof Set`) is what would close it.
    for tool in Write Edit MultiEdit; do
        assert_eq "C15-5 $tool: fail-OPEN characterization — malformed sids approves a live marker" \
            "approve" "$(_of_decide strsids "$tool" "wsid.workflow-off")"
    done
    assert_eq "C15-5 the Bash route ALSO approves here (no route is fail-closed)" "approve" \
        "$(gate_decision "$(_of_hook strsids "$(_c5_cmd "echo x > $OF_TGT_FWD/wsid.workflow-off")")")"
    assert_eq "C15-5 predicate: the bash spelling silently answers false on a string" "false" \
        "$(_of_probe strsids "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" wsid bash)"

    # C15-6 — `complete` a TRUTHY NON-BOOLEAN. `!complete` is the only test applied, so
    # the string "no" certifies an empty set as fully observed and every stem narrows out
    # of protection, on every route. Pinned because the SAFE-looking value is the falsy
    # one: a stringly-typed `complete` (JSON round-trip, IPC) leans open, not closed.
    # L3 gap: `complete !== true` at the consumption point is what would close it.
    for tool in Write Edit MultiEdit; do
        assert_eq "C15-6 $tool: fail-OPEN characterization — truthy non-boolean complete approves a live marker" \
            "approve" "$(_of_decide truthycomplete "$tool" "wsid.workflow-off")"
    done
    assert_eq "C15-6 the Bash route leans the same way" "approve" \
        "$(gate_decision "$(_of_hook truthycomplete "$(_c5_cmd "echo x > $OF_TGT_FWD/wsid.workflow-off")")")"
    assert_eq "C15-6 predicate: an empty set is treated as fully observed" "false" \
        "$(_of_probe truthycomplete "$PROBE_DIR/of-stem-probe.js" "$PB_NODE" wsid clean)"

    # C15-7 — the counterweight that keeps C15-4..6 from reading as "faults are harmless":
    # the SHAPE rule is observation-free, so a canonically sid-shaped stem stays blocked
    # under every one of the five broken observations. That is the residual protection an
    # attacker cannot reach through this dependency at all.
    for mode in throws nullret nosids strsids truthycomplete; do
        assert_eq "C15-7 [$mode] a canonical uuid stem is blocked without consulting the observation" "block" \
            "$(_of_decide "$mode" Write "3f2504e0-4f89-41d3-9a0c-0305e82c3301.off-clearance")"
    done
}
