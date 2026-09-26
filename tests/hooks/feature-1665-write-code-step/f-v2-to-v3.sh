# shellcheck shell=bash
# Tests: hooks/workflow-state/state-io/migrations/v2-to-v3.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/projection.js
# Tags: TL2, workflow, write-code, state-io, migration, schema-version, idempotency, scope:issue-specific, pwsh-not-required
#
# Case group F (TL2): the v2 -> v3 migration stage.
#
# Background: #1665 inserted write_code into VALID_STEPS between review_tests and
# run_tests. Every state file written before that insertion has no write_code
# step_status event at all, so the projection defaults it to `pending` while
# run_tests is already complete — next-step then aborts a perfectly healthy
# session. Schema v3 is how a file DECLARES "my writer knew about write_code",
# and migrations/v2-to-v3.js is the stage that raises everything older, backfilling
# write_code=complete only when a step AFTER it is already settled.
#
# These cases drive the real reader (readState / normalizeStateVersion /
# persistMigratedState) against hand-built on-disk fixtures, so the backfill
# predicate, the stream invariants it must preserve (seq contiguity, provenance
# vocabulary), and its idempotency are all observed through the public path.
#
# No Config-dependent case exists here on purpose: the stage reads no env var and
# no agents-config toggle — its whole input is the parsed state object — so there
# is no configuration axis for a case to pin.

SIO_N="$AGENTS_DIR_N/hooks/workflow-state/state-io"
CORE_N="$AGENTS_DIR_N/hooks/workflow-state/state-io/core.js"
PROJ_N="$AGENTS_DIR_N/hooks/workflow-state/state-io/projection.js"
MIGV3_N="$AGENTS_DIR_N/hooks/workflow-state/state-io/migrations/v2-to-v3.js"

# Shared JS preamble: everything a case needs to reach the fixture it just wrote.
V3PRE='const S = require(process.env.SIO_N);
const CORE = require(process.env.CORE_N);
const PROJ = require(process.env.PROJ_N);
const fs = require("fs"), path = require("path");
const sid = process.env.V3_SID;
const sp = () => path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json");
const raw = () => fs.readFileSync(sp(), "utf8");
const rd = () => JSON.parse(raw());
const norm = () => CORE.normalizeStateVersion(S.readRawState(sid));
const wc = (st) => (st.current || st).steps.write_code;
'

# v3_node <sid> <js> — one node process against the fixture for <sid>.
v3_node() {
  local sid="$1" js="$2"
  V3_SID="$sid" SIO_N="$SIO_N" CORE_N="$CORE_N" PROJ_N="$PROJ_N" MIGV3_N="$MIGV3_N" \
    run_with_timeout node -e "$V3PRE$js" 2>&1
}

# mk_stream <sid> <version> <step=status;...> [extra-events-json]
#   Builds a versioned state file whose events[] is exactly the listed
#   step_status records: seq 1..N, one hour apart, provenance "observed" — i.e.
#   a stream assertStreamIntegrity already accepts, so any later complaint is
#   attributable to the migration and not to the fixture.
mk_stream() {
  local sid="$1" ver="$2" spec="$3" extra="${4:-[]}"
  V3_SID="$sid" MK_VER="$ver" MK_SPEC="$spec" MK_EXTRA="$extra" \
    run_with_timeout node -e '
const fs = require("fs"), path = require("path");
const spec = (process.env.MK_SPEC || "").split(";").filter(Boolean);
const events = spec.map((p, i) => {
  const [step, status] = p.split("=");
  return {
    kind: "step_status", step, status,
    at: new Date(Date.UTC(2026, 0, 1, i)).toISOString(),
    provenance: "observed", origin: "fixture-1665-f",
  };
});
for (const e of JSON.parse(process.env.MK_EXTRA)) events.push(e);
events.forEach((e, i) => { e.seq = i + 1; });
const out = {
  version: Number(process.env.MK_VER),
  session_id: process.env.V3_SID,
  created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: null, git_branch: null },
  workflow_type: "wf-code",
  events,
};
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.V3_SID + ".json"),
                 JSON.stringify(out, null, 2));
' 2>&1
}

# Everything up to and including review_tests, with write_code deliberately absent.
UPTO_REVIEW_TESTS="workflow_init=complete;clarify_intent=complete;research=skipped;outline=complete;detail=complete;branching_complete=complete;write_tests=complete;review_tests=complete"

run_v2_to_v3_tests() {
  local out

  # ── Normal: the backfill fires ────────────────────────────────────────────
  mk_stream f-fires 2 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-fires '
const n = norm();
const before = rd().events.length;
const ev = n.events.filter((e) => e.kind === "step_status" && e.step === "write_code");
let integrity = "ok";
try { PROJ.assertStreamIntegrity(n.events); } catch (e) { integrity = e.name; }
const contiguous = n.events.every((e, i) => e.seq === i + 1);
console.log([
  "version=" + n.version,
  "status=" + wc(S.readState(sid)).status,
  "events_added=" + (n.events.length - before),
  "wc_events=" + ev.length,
  "provenance=" + ev[0].provenance,
  "origin=" + ev[0].origin,
  "at_estimated=" + ev[0].at_estimated,
  "integrity=" + integrity,
  "contiguous=" + contiguous,
].join(" "));
')"
  check "F1: a settled downstream step backfills write_code as complete" \
    "version=3 status=complete events_added=1 wc_events=1 provenance=backfilled origin=migration-v2-to-v3 at_estimated=true integrity=ok contiguous=true" \
    "$out"

  # A SKIPPED downstream step is settled too (CPR-ORTH with F1's complete).
  mk_stream f-skipped 2 "$UPTO_REVIEW_TESTS;review_security=skipped" >/dev/null
  out="$(v3_node f-skipped 'console.log(wc(S.readState(sid)).status + " " + norm().events.length);')"
  check "F2: a SKIPPED downstream step settles write_code just as a complete one does" \
    "complete 10" "$out"

  # ── Edge: nothing downstream is settled ───────────────────────────────────
  mk_stream f-early 2 "workflow_init=complete;clarify_intent=complete;write_tests=complete" >/dev/null
  out="$(v3_node f-early '
const n = norm();
console.log("version=" + n.version + " status=" + wc(S.readState(sid)).status +
            " events_added=" + (n.events.length - rd().events.length));
')"
  check "F3: with nothing settled after write_code the step stays pending" \
    "version=3 status=pending events_added=0" "$out"

  # in_progress is NOT settled: the downstream step is still running, so the
  # implementation body it depends on cannot be assumed finished.
  mk_stream f-inprog 2 "$UPTO_REVIEW_TESTS;run_tests=in_progress" >/dev/null
  out="$(v3_node f-inprog 'console.log(wc(S.readState(sid)).status + " " + (norm().events.length - rd().events.length));')"
  check "F4: an in_progress downstream step does not settle write_code" "pending 0" "$out"

  # ── Idempotency / non-interference: the stream already mentions write_code ─
  mk_stream f-explicit-pending 2 "$UPTO_REVIEW_TESTS;write_code=pending;run_tests=complete" >/dev/null
  out="$(v3_node f-explicit-pending '
const n = norm();
console.log("status=" + wc(S.readState(sid)).status +
            " events_added=" + (n.events.length - rd().events.length));
')"
  check "F5: an explicitly recorded pending write_code is never overwritten" \
    "status=pending events_added=0" "$out"

  mk_stream f-explicit-complete 2 "$UPTO_REVIEW_TESTS;write_code=complete;run_tests=complete" >/dev/null
  out="$(v3_node f-explicit-complete '
const n = norm();
const ev = n.events.filter((e) => e.kind === "step_status" && e.step === "write_code");
console.log("status=" + wc(S.readState(sid)).status + " wc_events=" + ev.length +
            " provenance=" + ev[0].provenance +
            " events_added=" + (n.events.length - rd().events.length));
')"
  check "F6: an already-recorded write_code keeps its own provenance" \
    "status=complete wc_events=1 provenance=observed events_added=0" "$out"

  # An ANNOTATION is not a status record: it can be attached to a step that was
  # never run, so it must not suppress the backfill.
  mk_stream f-annot 2 "$UPTO_REVIEW_TESTS;run_tests=complete" \
    '[{"kind":"step_annotation","step":"write_code","key":"token","value":"t","at":"2026-01-02T00:00:00.000Z","provenance":"observed","origin":"fixture-1665-f"}]' >/dev/null
  out="$(v3_node f-annot 'console.log(wc(S.readState(sid)).status + " " + (norm().events.length - rd().events.length));')"
  check "F7: a write_code ANNOTATION alone does not suppress the backfill" "complete 1" "$out"

  # ── Edge: degenerate streams ──────────────────────────────────────────────
  mk_stream f-empty 2 "" >/dev/null
  out="$(v3_node f-empty 'const n = norm(); console.log("version=" + n.version + " events=" + n.events.length + " status=" + wc(S.readState(sid)).status);')"
  check "F8: an empty v2 stream raises to v3 without fabricating anything" \
    "version=3 events=0 status=pending" "$out"

  # ── Chain: a v1 file runs through BOTH stages ─────────────────────────────
  out="$(v3_node f-v1-chain '
fs.writeFileSync(sp(), JSON.stringify({
  version: 1, session_id: sid, created_at: "2026-01-01T00:00:00.000Z",
  workflow_type: "wf-code",
  steps: {
    workflow_init: { status: "complete", updated_at: "2026-01-01T01:00:00.000Z" },
    review_tests: { status: "complete", updated_at: "2026-01-01T02:00:00.000Z" },
    run_tests: { status: "complete", updated_at: "2026-01-01T03:00:00.000Z" },
  },
}, null, 2));
const n = norm();
const ev = n.events.filter((e) => e.kind === "step_status" && e.step === "write_code");
let integrity = "ok";
try { PROJ.assertStreamIntegrity(n.events); } catch (e) { integrity = e.name; }
console.log("version=" + n.version + " status=" + wc(S.readState(sid)).status +
            " provenance=" + ev[0].provenance + " seq=" + ev[0].seq +
            " last=" + (ev[0].seq === n.events.length) + " integrity=" + integrity);
')"
  check "F9: a v1 file chains v1->v2->v3 and is backfilled at the tail" \
    "version=3 status=complete provenance=backfilled seq=4 last=true integrity=ok" "$out"

  # ── Error: a file from a newer release stays opaque ───────────────────────
  mk_stream f-future 4 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-future '
let thrown = "none";
try { norm(); } catch (e) { thrown = e.name; }
console.log("thrown=" + thrown + " read=" + String(S.readState(sid)) +
            " max=" + CORE.MAX_KNOWN_STATE_VERSION);
')"
  check "F10: a version above the current one still throws and fails open" \
    "thrown=FutureSchemaVersionError read=null max=3" "$out"

  # ── Idempotency: an already-v3 file is never re-migrated ──────────────────
  mk_stream f-idem 3 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-idem '
const before = raw();
const a = JSON.stringify(norm());
const b = JSON.stringify(norm());
S.readState(sid);
console.log("same=" + (a === b) + " no_write_code_event=" +
            !/"step":"write_code"/.test(a) + " bytes_untouched=" + (before === raw()));
')"
  check "F11: a v3 file is a no-op — no second backfill, no rewrite on read" \
    "same=true no_write_code_event=true bytes_untouched=true" "$out"

  # ── Classifier guard: the stage is a PURE function of its input ───────────
  mk_stream f-pure 2 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-pure '
const { migrateV2ToV3 } = require(process.env.MIGV3_N);
const input = rd();
const snapshot = JSON.stringify(input);
const a = JSON.stringify(migrateV2ToV3(input));
const b = JSON.stringify(migrateV2ToV3(input));
console.log("deterministic=" + (a === b) + " input_unmutated=" + (snapshot === JSON.stringify(input)));
')"
  check "F12: migrateV2ToV3 is deterministic and never mutates its input" \
    "deterministic=true input_unmutated=true" "$out"

  # ── The writer side: what this release stamps on disk ─────────────────────
  mk_stream f-persist 2 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-persist '
const first = S.persistMigratedState(sid);
const bytes = raw();
const second = S.persistMigratedState(sid);
console.log("migrated=" + first + " on_disk_version=" + rd().version +
            " second_call=" + second + " byte_identical=" + (bytes === raw()) +
            " projected=" + rd().current.steps.write_code.status);
')"
  check "F13: persistMigratedState writes v3 once and then reports nothing to do" \
    "migrated=true on_disk_version=3 second_call=false byte_identical=true projected=complete" "$out"

  # ── Error: a stream that was tampered with is not "repaired" by migrating ─
  # assertStreamIntegrity is tamper detection, and the migration must not launder
  # a broken stream into an acceptable one by appending to it. readState stays
  # fail-open (null), which is what every gate reads as "unknown state".
  mk_stream f-tampered 2 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-tampered '
const st = rd();
st.events[2].seq = 99;                        // out-of-band edit
fs.writeFileSync(sp(), JSON.stringify(st, null, 2));
let integrity = "ok";
try { PROJ.assertStreamIntegrity(norm().events); } catch (e) { integrity = e.name; }
console.log("integrity=" + integrity + " read=" + String(S.readState(sid)));
')"
  check "F15: a tampered stream stays broken through the migration and fails open" \
    "integrity=StreamIntegrityError read=null" "$out"

  # A v2 record whose `events` is not an array at all: the stage raises the
  # version and returns rather than throwing, and readState refuses the record.
  out="$(v3_node f-noevents '
fs.writeFileSync(sp(), JSON.stringify({
  version: 2, session_id: sid, created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: null, git_branch: null }, workflow_type: "wf-code",
  events: null,
}, null, 2));
let thrown = "none", version = "n/a";
try { version = norm().version; } catch (e) { thrown = e.name; }
console.log("thrown=" + thrown + " version=" + version + " read=" + String(S.readState(sid)));
')"
  check "F16: a v2 record with no events array raises the version without throwing" \
    "thrown=none version=3 read=null" "$out"

  # ── Edge: which timestamp the reconstructed record carries ────────────────
  # The stand-in is the LAST event own `at`, so the stream stays non-decreasing
  # in `at`; with no such timestamp anywhere it falls back to created_at.
  mk_stream f-at 2 "$UPTO_REVIEW_TESTS;run_tests=complete" >/dev/null
  out="$(v3_node f-at '
const tailAt = rd().events[rd().events.length - 1].at;
const migrated = norm().events;
const a = migrated[migrated.length - 1];
const nonDecreasing = migrated.every((e, i, arr) => i === 0 || String(arr[i - 1].at) <= String(e.at));
// Now strip the tail timestamp: with no `at` anywhere to borrow, created_at is
// the only stand-in left.
const st = rd();
delete st.events[st.events.length - 1].at;
fs.writeFileSync(sp(), JSON.stringify(st, null, 2));
const b = norm().events.slice(-1)[0];
console.log("uses_last_at=" + (a.at === tailAt) +
            " non_decreasing=" + nonDecreasing +
            " falls_back_to_created_at=" + (b.at === rd().created_at));
')"
  check "F17: the reconstructed record dates itself from the stream tail, then created_at" \
    "uses_last_at=true non_decreasing=true falls_back_to_created_at=true" "$out"

  out="$(v3_node f-newfile '
const init = S.createInitialState(sid, { cwd: null, git_branch: null });
const persisted = JSON.parse(S.serializeStateForPersist(init));
console.log("current=" + CORE.CURRENT_STATE_VERSION + " initial=" + init.version +
            " serialized=" + persisted.version);
')"
  check "F18: a freshly created state is stamped with CURRENT_STATE_VERSION" \
    "current=3 initial=3 serialized=3" "$out"
}
