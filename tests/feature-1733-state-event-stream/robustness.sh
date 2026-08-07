#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/robustness.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/lock.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/migrations.js, bin/workflow/set-workflow-type
# Tags: workflow-state, event-stream, security, error-handling, edge-case, path-traversal, malformed-input, forensic-integrity, schema-version, scope:issue-specific, pwsh-not-required, TL2
#
# Adversarial and malformed-input coverage for the append-only stream — the
# test-design.md categories the behavioural files above do not reach:
#   security  — the session id now resolves TWO paths (state file + lock file), so a
#               traversal-shaped id must not be able to split them across directories,
#               and no annotation value may leak into an error message.
#   error     — a v2 file whose `events` is not an array, or whose seq numbering is
#               broken by an out-of-band editor, must fail open rather than throw.
#   edge      — an empty stream, a single event, and a long stream (collection
#               boundaries), plus an extremely long annotation value.
#   forensic  — a state file that cannot be parsed at all is EVIDENCE. Every writer
#               must leave those bytes alone (X9), a file written by a NEWER schema
#               must not be downgraded in place (X10), and a malformed v2 stream must
#               not be folded into a status a gate would trust (X11).
#
# TL3 gap (what this test does NOT catch):
# - a real host's filesystem semantics for the lock file (SMB/network shares, a
#   read-only workflow dir, antivirus file locking on Windows). Everything here runs
#   on a local temp dir.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="rob"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== X1: a traversal-shaped session id is refused, and nothing outside the workflow dir is touched =="
if run_case "X1/traversal-refused"; then
    # The session id now resolves TWO paths (state file + lock file). The earlier
    # version of this case only asked that the two stay paired, which a traversal id
    # satisfies trivially by landing BOTH outside CLAUDE_WORKFLOW_DIR  a pair of files
    # written into someone else's directory is not a pass. The invariant asserted here
    # is absolute: a traversal-shaped id is refused outright, and the filesystem outside
    # the workflow dir is byte-identical afterwards.
    OUTSIDE="$TMPROOT/outside"
    mkdir -p "$OUTSIDE"
    printf 'canary\n' > "$OUTSIDE/canary.txt"
    X1_BEFORE="$(fs_snapshot "$TMPROOT" "$WF")"
    nodejs "x1" "$PRE"'
const L = require("./hooks/workflow-state/state-io/state-lock");
// Traversal shapes: relative escape, mid-string escape, Windows separator, NUL
// injection (written as an escape so this FILE stays text), and two absolute forms.
const bad = ["../evil", "a/../../evil", "..\evil", "a\u0000b", "/tmp/1733-abs-evil", "C:\1733-evil"];
const rows = bad.map((id, i) => {
  let wrote = "REFUSED", locked = "REFUSED";
  try { S.markStep(id, "research", "complete"); wrote = "ACCEPTED"; } catch (e) {}
  try { L.withStateLock(id, () => 1); locked = "ACCEPTED"; } catch (e) {}
  return "id" + i + "=" + wrote + "/" + locked;
});
console.log(rows.join(" "));
'
    X1_AFTER="$(fs_snapshot "$TMPROOT" "$WF")"
    x1_reason=""
    printf '%s' "$NODE_OUT" | grep -q "ACCEPTED" && x1_reason="a traversal id was accepted: $NODE_OUT"
    printf '%s' "$NODE_OUT" | grep -q "id5=" || x1_reason="${x1_reason:-node did not reach the last id: $NODE_OUT}"
    [ "$X1_BEFORE" = "$X1_AFTER" ] || x1_reason="${x1_reason:+$x1_reason; }filesystem outside $WF changed"
    if [ -z "$x1_reason" ]; then
        pass "X1/traversal-refused"
    else
        fail "X1/traversal-refused" "$x1_reason"
    fi
fi

echo "== X2: an adversarial annotation value is stored verbatim and never interpolated =="
if run_case "X2/annotation-value-not-interpolated"; then
    next_sid
    nodejs "$SID" "$PRE"'
// \x27 is a single quote: the JS body travels inside a single-quoted shell string.
const evil = "$(id) ${HOME} \x27; rm -rf /\x27 <script>x</script> %n";
S.markStep(sid, "research", "skipped", { skip_reason: evil });
const got = cur().steps.research.skip_reason;
// Round-tripped through JSON only: no shell, no template, no HTML escaping.
console.log("verbatim=" + (got === evil) + " on_disk_json=" + raw().includes(JSON.stringify(evil).slice(1, -1)));
'
    assert_eq "X2/annotation-value-not-interpolated" "verbatim=true on_disk_json=true" "$NODE_OUT"
fi

echo "== X3: an error message never quotes the annotation value that caused it =="
if run_case "X3/no-value-in-error"; then
    next_sid
    nodejs "$SID" "$PRE"'
const SECRET = "ghp_EXAMPLESECRET000000000000000000000000";
let msg = "NO-THROW";
try {
  const st = S.readState(sid) || S.createInitialState(sid, S.getCurrentContext());
  st.definitely_not_allowed = SECRET;
  S.writeState(sid, st);
} catch (e) { msg = String((e && e.message) || e) + "|" + String((e && e.stack) || ""); }
// The allowlist guard must name the KEY it rejected, never echo the value: state files
// carry tokens and shas, and hook stderr is surfaced to the transcript.
console.log("threw=" + (msg !== "NO-THROW") +
            " names_key=" + /definitely_not_allowed/.test(msg) +
            " leaks_value=" + msg.includes(SECRET));
'
    assert_eq "X3/no-value-in-error" "threw=true names_key=true leaks_value=false" "$NODE_OUT"
fi

echo "== X4: events that is not an array fails open (readState -> null, no throw) =="
if run_case "X4/events-not-array"; then
    for SHAPE in '"nope"' '42' 'null' '{}'; do
        next_sid
        nodejs_env "SHAPE=$SHAPE" "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const o = rd();
o.events = JSON.parse(process.env.SHAPE);
wraw(o);
let verdict = "NO-THROW";
let got;
try { got = S.readState(sid); } catch (e) { verdict = "THREW:" + e.name; }
// Treating the broken stream as empty and returning null are both acceptable
// fail-open answers. What is NOT acceptable is throwing (every hook would die) or
// folding the garbage into a status a gate would then trust.
const trusted = !!(got && got.steps && got.steps.workflow_init &&
                   got.steps.workflow_init.status === "complete");
console.log(verdict + " trusted_bogus_status=" + trusted);
'
        assert_eq "X4/events-not-array[$SHAPE]" "NO-THROW trusted_bogus_status=false" "$NODE_OUT"
    done
fi

echo "== X5: appendEvents REFUSES to append onto an already-broken seq sequence =="
if run_case "X5/broken-seq-refused"; then
    # AMENDED (codex review-tests HIGH finding 4). The earlier form of this case accepted
    # "the append repaired the numbering" as a pass. That is the wrong contract: `seq` is
    # the only thing that makes the stream orderable, so a stream that is ALREADY broken
    # is corrupt history, and rewriting it is destroying the evidence of the corruption —
    # not repairing it. An append onto a broken stream must be REFUSED, with the file left
    # byte-identical, so the break stays visible to whoever investigates.
    #
    # CURRENTLY RED — live defect: events.js unconditionally renumbers the whole merged
    # array on every append (`for (i...) merged[i].seq = i + 1`), so seed [1, 99] + one
    # appended event silently becomes [1, 2, 3] and the file is rewritten.
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete");
const o = rd();
o.events[1].seq = 99;              // out-of-band edit: a gap no appender could produce
wraw(o);
const before = raw();
let verdict = "ACCEPTED";
try { E.appendEvents(sid, [{ kind: "step_status", step: "research", status: "complete",
                            provenance: "observed", origin: "test" }]); }
catch (e) { verdict = "REFUSED:" + e.name; }
const after = raw();
// seqs is printed rather than a derived boolean so a failure names the exact damage:
// "1,2,3" is the destructive renumber, "1,99" is the intact (refused) stream.
console.log("refused=" + (verdict !== "ACCEPTED") +
            " unchanged=" + (after === before) +
            " seqs=" + rd().events.map((e) => e.seq).join(","));
'
    assert_eq "X5/broken-seq-refused" "refused=true unchanged=true seqs=1,99" "$NODE_OUT"
fi

echo "== X6: collection boundaries — 0, 1 and 250 events all fold correctly =="
if run_case "X6/stream-length-boundaries"; then
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
// 0 events: an initial state has an empty stream and still projects every step.
S.writeState(sid, S.createInitialState(sid, S.getCurrentContext()));
const zero = rd().events.length + "/" + Object.keys(S.readState(sid).steps).length;
// 1 event.
S.markStep(sid, "workflow_init", "complete");
const one = rd().events.length + "/" + S.readState(sid).steps.workflow_init.status;
// 250 events in one batch: no truncation, no renumbering drift, still contiguous.
const batch = [];
for (let i = 0; i < 249; i++) {
  batch.push({ kind: "step_annotation", step: "research", key: "note_" + i, value: i,
               provenance: "observed", origin: "test" });
}
E.appendEvents(sid, batch);
const ev = rd().events;
console.log("zero=" + zero + " one=" + one + " n=" + ev.length +
            " contiguous=" + ev.every((e, i) => e.seq === i + 1) +
            " last_note=" + S.readState(sid).steps.research.note_248);
'
    # zero= carries the VALID_STEPS count, which is asserted in final-report-step.sh —
    # matched loosely here so this case does not have to change when a step is added.
    if printf '%s' "$NODE_OUT" | grep -qE "^zero=0/1[0-9] one=1/complete n=250 contiguous=true last_note=248$"; then
        pass "X6/stream-length-boundaries"
    else
        fail "X6/stream-length-boundaries" "$NODE_OUT"
    fi
fi

echo "== X7: an extremely long annotation value survives a round trip intact =="
if run_case "X7/long-value-roundtrip"; then
    next_sid
    nodejs "$SID" "$PRE"'
const big = "x".repeat(64 * 1024) + "☃";
S.markStep(sid, "review_tests", "pending", { invalidate_reason: big });
const got = cur().steps.review_tests.invalidate_reason;
console.log("len=" + (got || "").length + " intact=" + (got === big) +
            " events=" + rd().events.length);
'
    assert_eq "X7/long-value-roundtrip" "len=65537 intact=true events=2" "$NODE_OUT"
fi

echo "== X8: an empty-string and a whitespace session id are refused, not written =="
if run_case "X8/empty-session-id"; then
    nodejs "x8" "$PRE"'
const before = fs.readdirSync(process.env.CLAUDE_WORKFLOW_DIR).length;
const results = ["", "   ", null, undefined].map((s) => {
  try { S.markStep(s, "workflow_init", "complete"); return "WROTE"; }
  catch (e) { return "REFUSED"; }
});
const after = fs.readdirSync(process.env.CLAUDE_WORKFLOW_DIR).length;
console.log(results.join(",") + " new_files=" + (after - before));
'
    # Fail-open (no throw) is acceptable; creating a junk state file is not.
    if printf '%s' "$NODE_OUT" | grep -q "new_files=0"; then pass "X8/empty-session-id"
    else fail "X8/empty-session-id" "$NODE_OUT"; fi
fi

echo "== X9: every writer leaves an UNPARSEABLE state file byte-identical (forensic evidence) =="
if run_case "X9/corrupt-state-not-clobbered"; then
    # NEW (codex review-tests HIGH finding 1). A truncated/invalid state file is the only
    # forensic record of whatever produced it — a crashed writer, a full disk, an
    # out-of-band editor. Overwriting it with a freshly created initial state destroys
    # that record AND silently resurrects a session whose real history is gone.
    #
    # The assertion is a BYTE diff (read the file before, read it again after), not a
    # "did it throw" check: a writer may legitimately fail open, but it may not write.
    #
    # CURRENTLY RED — live defect: readRawState() returns null on JSON.parse failure, so
    # markStep/appendEvents/updateTopLevel/set-workflow-type all fall through to
    # createInitialState() and writeStateLocked() replaces the corrupt bytes.
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
const { spawnSync } = require("child_process");
// Truncated mid-event: valid JSON prefix, unparseable as a whole.
const CORRUPT = "{\"version\": 2, \"session_id\": \"corrupt\", \"events\": [{\"kind\": \"step_stat";
const p = (s) => path.join(process.env.CLAUDE_WORKFLOW_DIR, s + ".json");
const seed = (s) => { fs.writeFileSync(p(s), CORRUPT, "utf8"); return fs.readFileSync(p(s)); };
const probe = (label, suffix, fn) => {
  const s = sid + "-" + suffix;
  const before = seed(s);
  try { fn(s); } catch (e) { /* failing open is allowed; WRITING is not */ }
  const after = fs.existsSync(p(s)) ? fs.readFileSync(p(s)) : Buffer.from("<DELETED>");
  return label + "=" + (Buffer.compare(before, after) === 0 ? "preserved" : "CLOBBERED");
};
console.log([
  probe("markStep", "mk", (s) => S.markStep(s, "research", "complete")),
  probe("appendEvents", "ae", (s) => E.appendEvents(s, [{ kind: "step_status", step: "research",
      status: "complete", provenance: "observed", origin: "test" }])),
  probe("updateTopLevel", "ut", (s) => S.updateTopLevel(s, (r) => { r.workflow_type = "wf-meta"; })),
  // The CLI is spawned as a real process (it is a separate entrypoint into updateTopLevel,
  // and a module-level assertion cannot see its argv handling).
  probe("setWorkflowTypeCli", "cli", (s) => spawnSync(process.execPath,
      [path.join(process.cwd(), "bin", "workflow", "set-workflow-type"), s, "wf-meta"],
      { encoding: "utf8" })),
].join(" "));
'
    assert_eq "X9/corrupt-state-not-clobbered" \
        "markStep=preserved appendEvents=preserved updateTopLevel=preserved setWorkflowTypeCli=preserved" \
        "$NODE_OUT"
fi

echo "== X10: a FUTURE schema version is never silently downgraded to v2 =="
if run_case "X10/future-schema-not-downgraded"; then
    # NEW (codex review-tests HIGH finding 2). A `version: 3` file was written by a newer
    # release of this repo — possibly by another concurrent session on the same machine
    # after an upgrade. This code cannot know what v3 means, so the only safe answers are
    # "refuse" or "fail open and leave it alone". Rewriting it as v2 downgrades a file
    # this process does not understand and destroys whatever v3 added.
    #
    # The assertion is on the ON-DISK version after each operation, which covers both safe
    # answers at once: a refusal and a fail-open read both leave `version: 3` on disk.
    #
    # CURRENTLY RED — live defect: normalizeStateVersion() branches only on `version === 2`
    # and treats EVERYTHING else as v1, so a v3 file is fed to migrateV1ToV2() and
    # persistMigratedState() writes it back as version 2 (dropping unknown top-level keys).
    next_sid
    nodejs "$SID" "$PRE"'
const V3 = (s) => JSON.stringify({
  version: 3,
  session_id: s,
  created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: null, git_branch: null },
  workflow_type: "wf-code",
  events: [{ kind: "step_status", step: "workflow_init", status: "complete",
             at: "2026-01-01T00:00:00.000Z", provenance: "observed", origin: "v3-fixture", seq: 1 }],
  // A key only the newer schema knows about: it must not be quietly dropped either.
  future_only_field: { note: "written by a newer release" },
}, null, 2);
const p = (s) => path.join(process.env.CLAUDE_WORKFLOW_DIR, s + ".json");
const seed = (s) => { fs.writeFileSync(p(s), V3(s), "utf8"); return s; };
const diskVersion = (s) => { try { return JSON.parse(fs.readFileSync(p(s), "utf8")).version; }
                             catch (e) { return "UNPARSEABLE"; } };
const keptFutureKey = (s) => { try { return "future_only_field" in JSON.parse(fs.readFileSync(p(s), "utf8")); }
                               catch (e) { return false; } };

const a = seed(sid + "-read");
let readBack = null;
try { readBack = S.readState(a); } catch (e) { readBack = { threw: true }; }

const b = seed(sid + "-persist");
try { S.persistMigratedState(b); } catch (e) {}

const c = seed(sid + "-mark");
try { S.markStep(c, "research", "complete"); } catch (e) {}

console.log("read_disk_v=" + diskVersion(a) +
            " read_downgraded=" + !!(readBack && readBack.version === 2) +
            " persist_disk_v=" + diskVersion(b) +
            " mark_disk_v=" + diskVersion(c) +
            " future_key_kept=" + keptFutureKey(a));
'
    assert_eq "X10/future-schema-not-downgraded" \
        "read_disk_v=3 read_downgraded=false persist_disk_v=3 mark_disk_v=3 future_key_kept=true" \
        "$NODE_OUT"
fi

echo "== X11: a malformed v2 stream yields no trusted status, and reading mutates nothing =="
if run_case "X11/malformed-stream-not-trusted"; then
    # NEW (codex review-tests HIGH finding 3). X4 already covers `events` not being an
    # array. This case covers the harder shape: `events` IS a well-formed array whose
    # RECORDS are corrupt. Six independent corruptions of the second event, each of which
    # a legitimate appender can never produce, so their presence proves the stream was
    # edited out of band:
    #   missing_seq / duplicate_seq / out_of_order — the ordering identity is destroyed,
    #                                                so "the latest status" is undecidable
    #   invalid_status / invalid_provenance / missing_provenance — validateEvent() would
    #                                                have refused these on the write path
    #
    # Two assertions per variant, and they are separate concerns (CPR-SC):
    #   trusted_complete=false — a gate must not read `complete` off a stream it can see
    #                            has been tampered with (the FIRST event is a genuine
    #                            workflow_init complete; the point is that a corrupt
    #                            NEIGHBOUR must taint the whole fold, not just itself)
    #   unchanged=true         — readState is a READ. It must not rewrite the file it
    #                            just found to be corrupt.
    #
    # CURRENTLY RED for most variants — live defect: projectState() never inspects `seq`
    # or `provenance` at all and assigns `steps[step].status = e.status` verbatim, so the
    # fold reports a trusted `complete` from a tampered stream.
    for VARIANT in missing_seq duplicate_seq out_of_order invalid_status invalid_provenance missing_provenance; do
        next_sid
        nodejs_env "VARIANT=$VARIANT" "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete");
const o = rd();
const e2 = o.events[1];
switch (process.env.VARIANT) {
  case "missing_seq": delete e2.seq; break;
  case "duplicate_seq": e2.seq = o.events[0].seq; break;
  case "out_of_order": o.events[0].seq = 2; e2.seq = 1; break;
  case "invalid_status": e2.status = "totally-bogus"; break;
  case "invalid_provenance": e2.provenance = "fabricated"; break;
  case "missing_provenance": delete e2.provenance; break;
  default: throw new Error("unknown variant");
}
wraw(o);
const before = raw();
let verdict = "NO-THROW";
let got;
try { got = S.readState(sid); } catch (e) { verdict = "THREW:" + e.name; }
const after = raw();
const trusted = !!(got && got.steps && got.steps.workflow_init &&
                   got.steps.workflow_init.status === "complete");
console.log(verdict + " trusted_complete=" + trusted + " unchanged=" + (after === before));
'
        assert_eq "X11/malformed-stream-not-trusted[$VARIANT]" \
            "NO-THROW trusted_complete=false unchanged=true" "$NODE_OUT"
    done
fi

finish "robustness"
