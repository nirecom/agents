#!/usr/bin/env bash
# Tests: hooks/workflow-state/session-id.js, hooks/lib/active-session-ids.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js
# Tags: active-session-ids, resolve-session-id, fail-closed, fault-injection, structured-editor, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section C16 — resolveSessionId() faulted AT ITS OWN CALL SITE inside
# observeActiveSessionIds() (active-session-ids.js:71-79). C15 replaces
# observeActiveSessionIds itself, so that try/catch never runs there; C12-4b faults the
# notes enumeration, a different dependency with its own handling. Only here is the
# catch the thing under test — and only here is its verdict carried out to the real
# gate, so "fail-closed" is observed end-to-end rather than inferred from a return value.
RS_WF=""
RS_TGT_FWD=""
RS_TGT_SH=""
RS_CFG=""
RS_CWD=""
RS_PRELOAD_SH=""
RS_PRELOAD_NODE=""
RS_SIDMOD_NODE=""

# Seeded into a live session's marker before a forged write is attempted (C16-5).
RS_GENUINE="GENUINE-RESOLVE-FAULT-BODY"

# The id the `ghost` mode makes resolveSessionId answer with. Not sid-SHAPED, so the
# shape rule cannot protect it — only the resolver's return value can.
RS_GHOST="resolver-ghost-sid"

_rs_write_probes() {
    cat > "$PROBE_DIR/rs-resolve-fault-preload.js" <<'PROBE_EOF'
"use strict";
// `node -r THIS`: replaces resolveSessionId() in the require cache BEFORE
// active-session-ids.js destructures it at module load (line 17). That destructuring is
// why the swap must happen in a preload: once active-session-ids.js holds the function
// value, no later assignment to session-id.js's exports can reach it.
// env: RS_MODULE (absolute path to hooks/workflow-state/session-id.js), RS_FAULT_MODE.
// Only active-session-ids.js consumes this export inside block-clearance-token-write's
// require graph, so the swap reaches exactly one call site.
const p = require.resolve(process.env.RS_MODULE);
require(p);
const faults = {
  // THE REQUIREMENT: a throwing resolver. active-session-ids.js:77-79 must absorb it
  // into `complete:false` — not re-throw, and not narrow on a half-built set.
  throws: () => { throw new Error("session resolution exploded"); },
  // The module's OWN documented non-fault: "a null return is an ANSWER, not a fault".
  nullret: () => null,
  // Same class: an empty string is filtered by the `resolved !== ""` guard, and is not
  // a fault either — pinned because dropping that guard would add "" to the set.
  emptystr: () => "",
  // Not a fault at all: a resolver that answers an arbitrary id. Proves the swap really
  // reaches the call site and that its return value is TRUSTED into the observed set.
  ghost: () => process.env.RS_GHOST_ID || "resolver-ghost-sid",
};
const f = faults[process.env.RS_FAULT_MODE || ""];
if (f) {
  require.cache[p].exports = Object.assign({}, require.cache[p].exports, {
    resolveSessionId: f,
  });
}
PROBE_EOF
    cat > "$PROBE_DIR/rs-observe-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <active-session-ids.js> <ctx-json> -> "<complete>|<sids, sorted>", or "THREW".
// THREW is a distinct outcome on purpose: it separates "the catch absorbed the fault
// into complete:false" (the contract) from "the fault escaped to the caller".
const m = require(process.argv[2]);
try {
  const r = m.observeActiveSessionIds(JSON.parse(process.argv[3] || "{}"));
  process.stdout.write(String(r.complete) + "|" + Array.from(r.sids).sort().join(","));
} catch (_) { process.stdout.write("THREW"); }
PROBE_EOF
    cat > "$PROBE_DIR/rs-stem-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <protected-basenames.js> <stem> <spelling> <sid> -> "true"|"false"|"THREW".
const p = require(process.argv[2]);
try {
  process.stdout.write(String(p.isClearanceBearingStem(process.argv[3], {
    spelling: process.argv[4],
    sessionCtx: { sessionId: process.argv[5] },
  })));
} catch (_) { process.stdout.write("THREW"); }
PROBE_EOF
}

# _rs_probe <mode> <probe-args...>
_rs_probe() {
    local mode="$1"; shift
    (
        cd "$RS_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export CLAUDE_WORKFLOW_DIR="$RS_WF" WORKFLOW_PLANS_DIR="$RS_WF"
        export RS_MODULE="$RS_SIDMOD_NODE" RS_FAULT_MODE="$mode" RS_GHOST_ID="$RS_GHOST"
        run_probe -r "$RS_PRELOAD_SH" "$@"
    )
}

# _rs_hook <mode> <stdin-json> -> raw block-clearance-token-write stdout
_rs_hook() {
    local mode="$1" input="$2"
    (
        cd "$RS_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export AGENTS_CONFIG_DIR="$RS_CFG"
        export CLAUDE_WORKFLOW_DIR="$RS_WF" WORKFLOW_PLANS_DIR="$RS_WF"
        export RS_MODULE="$RS_SIDMOD_NODE" RS_FAULT_MODE="$mode" RS_GHOST_ID="$RS_GHOST"
        # NATIVE preload path: run_hook_capture sets MSYS_NO_PATHCONV=1.
        run_hook_capture "$input" "$RWT" 20 node -r "$RS_PRELOAD_NODE" "$BCTW_HOOK"
    )
}

# _rs_decide <mode> <tool> <basename> -> approve | block | crash | timeout
_rs_decide() {
    gate_decision "$(_rs_hook "$1" "$(mk_edit_input "$2" wsid "$RS_TGT_FWD/$3")")"
}

# _rs_bash <mode> <basename> -> decision on a redirect onto that basename
_rs_bash() {
    gate_decision "$(_rs_hook "$1" "$(_c5_cmd "echo x > $RS_TGT_FWD/$2")")"
}

_rs_read() { if [ -e "$1" ]; then cat "$1"; else printf '<absent>'; fi; }

# _rs_gated_write <mode> <tool> <basename> <content> -> decision; the tool action is
# really performed on approve, so a negative row can assert the file, not the text.
_rs_gated_write() {
    local mode="$1" tool="$2" bn="$3" content="$4" d
    d="$(_rs_decide "$mode" "$tool" "$bn")"
    [ "$d" = "approve" ] && printf '%s' "$content" > "$RS_TGT_SH/$bn"
    printf '%s' "$d"
}

_rs_setup() {
    local base="$TMPBASE_SH/resolve-sid-fault"
    rm -rf "$base" 2>/dev/null || true
    mkdir -p "$base/wf" "$base/target" "$base/config" "$base/cwd"
    RS_WF="$(node_path "$base/wf")"
    RS_CFG="$(node_path "$base/config")"
    RS_TGT_FWD="$(node_path "$base/target")"
    RS_TGT_FWD="${RS_TGT_FWD//\\//}"
    RS_TGT_SH="$base/target"
    RS_CWD="$base/cwd"
    RS_PRELOAD_SH="$PROBE_DIR/rs-resolve-fault-preload.js"
    RS_PRELOAD_NODE="$(node_path "$PROBE_DIR")/rs-resolve-fault-preload.js"
    RS_SIDMOD_NODE="$AGENTS_NODE/hooks/workflow-state/session-id.js"
    # `wsid` is a REAL entry in the pinned store, so the unfaulted classifier protects
    # `wsid.workflow-off` and allows `issue-2108-survey.gh-env` — the two poles every row
    # below is measured against. The cwd holds no WORKTREE_NOTES.md, so the notes
    # enumeration contributes nothing and the resolver is the only moving part.
    printf '{"version":1,"session_id":"wsid"}' > "$base/wf/wsid.json"
    _rs_write_probes
}

run_C16_resolve_sid_fault() {
    local tool mode

    _rs_setup

    if [ -f "$AGENTS_DIR/hooks/workflow-state/session-id.js" ]; then
        pass "C16-0 workflow-state/session-id.js present"
    else
        fail "C16-0 hooks/workflow-state/session-id.js MISSING - Section C16 would be vacuous"
        return
    fi

    # C16-0 — HARNESS CONTROL. The preload is loaded but selects no fault: both poles must
    # read exactly as they do without it, on all three editors and on the bash route. A
    # broken preload (wrong module path, swap too late) would otherwise leave every fault
    # row below measuring the UNfaulted resolver, and passing for the wrong reason.
    for tool in Write Edit MultiEdit; do
        assert_eq "C16-0 control ($tool): a live session's marker is blocked, no fault" "block" \
            "$(_rs_decide none "$tool" "wsid.workflow-off")"
        assert_eq "C16-0 control ($tool): the #2108 artifact stem still writes" "approve" \
            "$(_rs_decide none "$tool" "issue-2108-survey.gh-env")"
    done
    assert_eq "C16-0 control (bash): the #2108 artifact stem still writes" "approve" \
        "$(_rs_bash none "issue-2108-survey.gh-env")"
    assert_eq "C16-0 control: the observation is complete and holds only the live sid" "true|wsid" \
        "$(_rs_probe none "$PROBE_DIR/rs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"

    # C16-0b — POSITIVE CONTROL that the swap reaches THIS call site. `ghost` is not a
    # fault: the resolver simply answers an id, and that id must appear in the observed
    # set. If the require-cache swap landed too late this row would read "true|wsid",
    # identical to C16-0, and every fault row below would be measuring the real resolver.
    assert_eq "C16-0b the resolver's return value is trusted into the observed set" \
        "true|$RS_GHOST,wsid" \
        "$(_rs_probe ghost "$PROBE_DIR/rs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_eq "C16-0b ... so that id becomes clearance-bearing end-to-end (blocked)" "block" \
        "$(_rs_decide ghost Write "$RS_GHOST.workflow-off")"
    assert_eq "C16-0b ... while the unfaulted resolver leaves the same name writable" "approve" \
        "$(_rs_decide none Write "$RS_GHOST.workflow-off")"

    # C16-1 — THE REQUIREMENT, at the observation layer. A throwing resolveSessionId must
    # be ABSORBED by the try/catch at active-session-ids.js:71-79 into `complete:false`.
    # Two wrong outcomes are excluded at once: "THREW" (the fault escaped, leaving each
    # caller's own error boundary to decide) and "true|wsid" (swallowed into a set that
    # still claims completeness — the fail-OPEN this module exists to prevent, since a
    # complete set narrows every unobserved stem out of protection).
    assert_eq "C16-1 a throwing resolveSessionId yields complete:false, not an escape" "false|wsid" \
        "$(_rs_probe throws "$PROBE_DIR/rs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"

    # C16-2 — and `complete:false` reaches the PREDICATE both write guards consult: with
    # no narrowing applied, the pre-#2108 suffix-only breadth returns on both spellings.
    assert_eq "C16-2 predicate: the artifact stem becomes bearing (clean spelling)" "true" \
        "$(_rs_probe throws "$PROBE_DIR/rs-stem-probe.js" "$PB_NODE" issue-2108-survey clean wsid)"
    assert_eq "C16-2 predicate: ... and on the bash spelling too" "true" \
        "$(_rs_probe throws "$PROBE_DIR/rs-stem-probe.js" "$PB_NODE" issue-2108-survey bash wsid)"
    # The counterweight: without the fault the same stem is NOT bearing, so C16-2 is a
    # discriminator rather than a predicate that answers true always.
    assert_eq "C16-2 control: unfaulted, the artifact stem is not bearing" "false" \
        "$(_rs_probe none "$PROBE_DIR/rs-stem-probe.js" "$PB_NODE" issue-2108-survey clean wsid)"

    # C16-3 — THE END-TO-END FAIL-CLOSED CONTRACT, through the real hook subprocess: the
    # verdict an agent actually receives, which C15 cannot show for this fault. Asserted
    # on each editor SEPARATELY plus Bash, because Write/Edit/MultiEdit reach the
    # predicate through a different branch of block-clearance-token-write/dispatch.js
    # than Bash does, with a different error boundary (CPR-ORTH).
    assert_eq "C16-3 the Bash route blocks an artifact stem while the resolver throws" "block" \
        "$(_rs_bash throws "issue-2108-survey.gh-env")"
    for tool in Write Edit MultiEdit; do
        assert_eq "C16-3 $tool: a throwing resolver blocks even an artifact stem (fail-closed)" "block" \
            "$(_rs_decide throws "$tool" "issue-2108-survey.gh-env")"
        assert_eq "C16-3 $tool: and the live marker stays blocked (no swap of the two poles)" "block" \
            "$(_rs_decide throws "$tool" "wsid.workflow-off")"
    done
    assert_eq "C16-3 the Bash route keeps the live marker blocked as well" "block" \
        "$(_rs_bash throws "wsid.workflow-off")"

    # C16-4 — THE NON-FAULTS, which keep C16-3 from reading as "any resolver oddity blocks
    # everything". `null` and `""` are documented ANSWERS: the observation stays complete,
    # the narrowing stays on, and the #2108 artifact keeps writing on every editor route.
    for tool in Write Edit MultiEdit; do
        assert_eq "C16-4 [nullret] $tool: a null answer is not a fault — the artifact still writes" \
            "approve" "$(_rs_decide nullret "$tool" "issue-2108-survey.gh-env")"
        assert_eq "C16-4 [emptystr] $tool: an empty answer likewise" \
            "approve" "$(_rs_decide emptystr "$tool" "issue-2108-survey.gh-env")"
    done
    assert_eq "C16-4 [nullret] the observation stays complete" "true|wsid" \
        "$(_rs_probe nullret "$PROBE_DIR/rs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_eq "C16-4 [emptystr] an empty id never enters the observed set" "true|wsid" \
        "$(_rs_probe emptystr "$PROBE_DIR/rs-observe-probe.js" "$ACTIVE_SIDS_NODE" '{"sessionId":"wsid"}')"
    assert_eq "C16-4 [nullret] and the live marker is still protected" "block" \
        "$(_rs_decide nullret Write "wsid.workflow-off")"

    # C16-5 — PATTERN 1 (protection-fix-tests.md): every row above reads the hook's
    # verdict only. Here the write is really PERFORMED whenever the hook approves, so a
    # guard that says "block" after the bytes have already landed cannot pass.
    printf '%s' "$RS_GENUINE" > "$RS_TGT_SH/wsid.workflow-off"
    assert_eq "C16-5 forged overwrite of a live marker under a throwing resolver is blocked" "block" \
        "$(_rs_gated_write throws Write "wsid.workflow-off" "FORGED-BY-C16")"
    assert_eq "C16-5 the seeded marker survived byte-for-byte" "$RS_GENUINE" \
        "$(_rs_read "$RS_TGT_SH/wsid.workflow-off")"
    # HARNESS PROOF: the helper must be ABLE to write, or the row above is false-green.
    assert_eq "C16-5 harness proof: an approved write really lands (unfaulted)" "approve" \
        "$(_rs_gated_write none Write "issue-2108-survey.gh-env" "ARTIFACT-BODY-C16")"
    assert_eq "C16-5 harness proof: ... and the bytes are on disk" "ARTIFACT-BODY-C16" \
        "$(_rs_read "$RS_TGT_SH/issue-2108-survey.gh-env")"

    # C16-6 — the observation-free residue: the SHAPE rule never consults the resolver, so
    # a canonically sid-shaped stem stays blocked under every mode above. That is the
    # protection an attacker cannot reach through this dependency at all.
    for mode in throws nullret emptystr ghost; do
        assert_eq "C16-6 [$mode] a canonical uuid stem is blocked without consulting the resolver" \
            "block" "$(_rs_decide "$mode" Write "3f2504e0-4f89-41d3-9a0c-0305e82c3301.off-clearance")"
    done
}
