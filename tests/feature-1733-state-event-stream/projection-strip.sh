#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/projection-strip.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/events.js
# Tags: workflow-state, event-stream, projection, allowlist, persistence, single-source-of-truth, scope:issue-specific, pwsh-not-required, TL2
#
# readState pastes a projection onto the state object; a naive JSON.stringify of that
# object would write the legacy fields straight back into the v2 file and create a
# SECOND state representation next to `events` (CPR-SSOT violation, and a fork that would
# silently diverge). serializeStateForPersist is the only guard: an allowlist plus a
# regenerated `current`. These cases assert the guard from the OUTSIDE — by the key set
# actually present in the bytes on disk — so an implementation that forgets one key
# cannot pass.
#
# TL3 gap (what this test does NOT catch):
# - a writer that bypasses the state layer entirely (a skill or script editing the
#   state file with jq/Write). Only file bytes are checked here, after writes that
#   went through the module.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

CASE_TAG="pstrip"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

FORBIDDEN="steps,plan_approvals,git_branch,cwd,is_bugfix,session_model,complexity_evaluation,skip_judgment,worktree_entered_at,worktree_exited_at"

echo "== S1: after real writes, no projection key is a top-level key on disk =="
if run_case "S1/no-projection-on-disk"; then
    next_sid
    nodejs_env "FORBIDDEN=$FORBIDDEN" "$SID" "$PRE$APPROVE_GATED_JS"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "outline", "complete");
S.recordSessionModel(sid, { id: "claude-opus-5", source: "transcript" });
S.recordComplexityEvaluation(sid, ["S1-multi-file", "S2-architecture"]);
S.markStep(sid, "research", "skipped", { skip_reason: "n/a", skip_judgment: { decision: "skip" } });
const onDisk = rd();
const present = process.env.FORBIDDEN.split(",").filter((k) => Object.prototype.hasOwnProperty.call(onDisk, k));
// The same facts must still be reachable — via .current, the human/jq snapshot.
const inCurrent = ["steps", "plan_approvals", "session_model", "complexity_evaluation"]
  .filter((k) => onDisk.current && onDisk.current[k] !== undefined);
console.log("leaked=" + (present.join(",") || "0") + " in_current=" + inCurrent.length);
'
    assert_eq "S1/no-projection-on-disk" "leaked=0 in_current=4" "$NODE_OUT"
fi

echo "== S2: the on-disk key set is a subset of PERSISTED_TOP_LEVEL_KEYS =="
if run_case "S2/allowlist-subset"; then
    next_sid
    nodejs "$SID" "$PRE"'
const PJ = require("./hooks/workflow-state/state-io/projection");
S.markStep(sid, "workflow_init", "complete");
S.setLastPushedSha(sid, "0".repeat(40));
S.recordSessionWorktree(sid, { path: "C:\\wt\\x" });
const keys = Object.keys(rd());
const outside = keys.filter((k) => !PJ.PERSISTED_TOP_LEVEL_KEYS.includes(k));
console.log("keys=" + keys.length + " outside_allowlist=" + (outside.join(",") || "0"));
'
    if printf '%s' "$NODE_OUT" | grep -q " outside_allowlist=0$"; then pass "S2/allowlist-subset"
    else fail "S2/allowlist-subset" "$NODE_OUT"; fi
fi

echo "== S3: read -> unchanged -> write, three times, does not grow the key set =="
if run_case "S3/roundtrip-idempotent"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const k0 = Object.keys(rd()).sort().join(",");
const sizes = [];
for (let i = 0; i < 3; i++) {
  const st = S.readState(sid);
  S.writeState(sid, st);
  sizes.push(Object.keys(rd()).sort().join(","));
}
const stable = sizes.every((k) => k === k0);
// Byte-equality of the last two round trips: the projection must not perturb anything.
const a = raw(); S.writeState(sid, S.readState(sid)); const b = raw();
console.log("key_set_stable=" + stable + " bytes_stable=" + (a === b));
'
    assert_eq "S3/roundtrip-idempotent" "key_set_stable=true bytes_stable=true" "$NODE_OUT"
fi

echo "== S4: a round trip never grows or reorders the event stream =="
if run_case "S4/roundtrip-events-untouched"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "run_tests", "complete", { note: "x" });
const before = JSON.stringify(rd().events);
for (let i = 0; i < 3; i++) S.writeState(sid, S.readState(sid));
console.log(JSON.stringify(rd().events) === before ? "IDENTICAL" : "CHANGED");
'
    assert_eq "S4/roundtrip-events-untouched" "IDENTICAL" "$NODE_OUT"
fi

echo "== S5: an unregistered top-level key makes writeState throw UnknownStateKeyError =="
if run_case "S5/unknown-key-fail-closed"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const before = raw();
const st = S.readState(sid);
st.some_unregistered_field = "surprise";
let verdict = "NO-THROW";
try { S.writeState(sid, st); } catch (e) { verdict = e && e.name === "UnknownStateKeyError" ? "UnknownStateKeyError" : "Other:" + (e && e.name); }
console.log(verdict + " unchanged=" + (before === raw()) + " leaked=" + /some_unregistered_field/.test(raw()));
'
    assert_eq "S5/unknown-key-fail-closed" "UnknownStateKeyError unchanged=true leaked=false" "$NODE_OUT"
fi

echo "== S6: current is regenerated on write, never trusted from the previous bytes =="
if run_case "S6/current-regenerated"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
// Poison `current` on disk. readState must re-fold from events and the next write
// must overwrite the poison — `current` is a snapshot, never the authority.
const st = rd();
st.current.steps.workflow_init = { status: "pending", updated_at: null };
st.current.git_branch = "poisoned";
wraw(st);
const read = S.readState(sid);
S.markStep(sid, "run_tests", "complete");
console.log("read_status=" + read.steps.workflow_init.status +
            " disk_status=" + cur().steps.workflow_init.status +
            " branch_poison=" + (cur().git_branch === "poisoned"));
'
    assert_eq "S6/current-regenerated" "read_status=complete disk_status=complete branch_poison=false" "$NODE_OUT"
fi

echo "== S7: appendEvents and persistMigratedState strip identically (CPR-ORTH symmetry) =="
if run_case "S7/all-write-paths-strip"; then
    next_sid; SID_A="$SID"
    next_sid; SID_B="$SID"
    MKV1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-v1.js"
    (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" toplevel) > "$WF/$SID_B.json"
    nodejs_env "SID_B=$SID_B FORBIDDEN=$FORBIDDEN" "$SID_A" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
const forbidden = process.env.FORBIDDEN.split(",");
const leaks = (s) => {
  const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, s + ".json");
  const o = JSON.parse(fs.readFileSync(p, "utf8"));
  return forbidden.filter((k) => Object.prototype.hasOwnProperty.call(o, k));
};
// path 1: appendEvents
E.appendEvents(sid, [{ kind: "step_status", step: "run_tests", status: "complete", provenance: "observed", origin: "test" }]);
// path 2: persistMigratedState on a v1 file that HAS every legacy top-level field
S.readState(process.env.SID_B);
S.persistMigratedState(process.env.SID_B);
console.log("append_leaks=" + (leaks(sid).join(",") || "0") +
            " migrate_leaks=" + (leaks(process.env.SID_B).join(",") || "0"));
'
    assert_eq "S7/all-write-paths-strip" "append_leaks=0 migrate_leaks=0" "$NODE_OUT"
fi

finish "projection-strip"
