#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/migration-concurrency.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/state-lock.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: workflow-state, event-stream, migration, concurrency, locking, fail-open, scope:issue-specific, pwsh-not-required, TL2
#
# readState now WRITES (lazy v1->v2 persistence). That opens a window: process A reads a
# v1 file, process B migrates it and appends new events, then A persists its own stale
# v1 snapshot and B's events vanish. The design closes the window with a single
# checkpoint — persistMigratedState re-reads INSIDE the lock and returns early when the
# file is already version 2. These cases drive both orderings of that race with real
# processes and a real file, so a regression in that early return is observable.
#
# TL3 gap (what this test does NOT catch):
# - the race as it actually occurs in Claude Code, where A and B are a PreToolUse gate
#   and a PostToolUse recorder for the same tool call rather than two `node -e` processes.
# - a filesystem where O_EXCL is not atomic (network-mounted ~/.claude).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="migconc"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MKV1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-v1.js"

seed_v1() { # <sid> <preset>
    (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" "$2") > "$WF/$1.json"
}

echo "== M1: B's appended events survive A's late persist of a stale v1 snapshot =="
if run_case "M1/late-persist-does-not-clobber"; then
    next_sid
    SID_1="$SID"
    seed_v1 "$SID_1" "ordering"

    # Process A: read the v1 file into memory, then WAIT for the barrier file before
    # persisting. The wait is what makes the stale-snapshot window observable; a
    # single-process test cannot hold a pre-migration snapshot across another writer.
    A_JS='const S = require("./hooks/workflow-state/state-io");
const fs = require("fs");
const sid = process.env.SID;
const snapshot = S.readState(sid);           // in-memory v1 -> v2 conversion
if (!snapshot) { console.log("A:READ-FAIL"); process.exit(0); }
fs.writeFileSync(process.env.BARRIER_A, "read-done");
const t0 = Date.now();
while (!fs.existsSync(process.env.BARRIER_B) && Date.now() - t0 < 30000) {}
try { S.persistMigratedState(sid); } catch (e) { console.log("A:THREW:" + (e && e.name)); }
console.log("A:DONE");
'
    (cd "$AGENTS_DIR" && env \
        CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID_1" \
        BARRIER_A="$TMPROOT/bar-a" BARRIER_B="$TMPROOT/bar-b" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 90 node -e "$A_JS" >"$TMPROOT/m1-a.out" 2>&1) &
    A_PID=$!

    # Wait for A to be holding its snapshot.
    for _ in $(seq 1 300); do [ -f "$TMPROOT/bar-a" ] && break; sleep 0.1; done

    nodejs "$SID_1" "$PRE"'
S.markStep(sid, "review_security", "complete", { marker: "from-B" });
console.log("B:" + (rd().version === 2 ? "v2" : "v" + rd().version));
'
    assert_eq "M1/B-migrated-and-appended" "B:v2" "$NODE_OUT"
    : > "$TMPROOT/bar-b"
    wait "$A_PID" || true
    A_OUT="$(cat "$TMPROOT/m1-a.out")"
    if printf '%s' "$A_OUT" | grep -q '^A:DONE$'; then pass "M1/A-completed-fail-open"
    else fail "M1/A-completed-fail-open" "$A_OUT"; fi

    nodejs "$SID_1" "$PRE"'
const st = rd();
const marker = st.events.some((e) => e.kind === "step_annotation" && e.key === "marker" && e.value === "from-B");
console.log("version=" + st.version +
            " B_event_present=" + marker +
            " review_security=" + cur().steps.review_security.status);
'
    assert_eq "M1/no-clobber" "version=2 B_event_present=true review_security=complete" "$NODE_OUT"
fi

echo "== M2: reverse order (A persists first, then B appends) is equally lossless =="
if run_case "M2/persist-then-append"; then
    next_sid
    SID_2="$SID"
    seed_v1 "$SID_2" "ordering"
    nodejs "$SID_2" "$PRE"'
S.readState(sid);
S.persistMigratedState(sid);
const v = rd().version;
S.markStep(sid, "review_security", "complete", { marker: "from-B" });
const st = rd();
console.log("after_persist=v" + v + " version=" + st.version +
            " B_event_present=" + st.events.some((e) => e.key === "marker"));
'
    assert_eq "M2/persist-then-append" "after_persist=v2 version=2 B_event_present=true" "$NODE_OUT"
fi

echo "== M3: migration is deterministic — both orderings agree on the migrated prefix =="
if run_case "M3/deterministic-prefix"; then
    next_sid; SID_3A="$SID"
    next_sid; SID_3B="$SID"
    seed_v1 "$SID_3A" "ordering"
    seed_v1 "$SID_3B" "ordering"
    # 3A: migrate via persistMigratedState, then append.  3B: append first (which
    # migrates in-lock), no explicit persist. The MIGRATED PREFIX must be identical:
    # the conversion is a pure function of the v1 bytes, so the route cannot matter.
    nodejs "$SID_3A" "$PRE"'
S.readState(sid); S.persistMigratedState(sid);
S.markStep(sid, "review_security", "complete");
const n = rd().events.length;
fs.writeFileSync(process.env.CLAUDE_WORKFLOW_DIR + "/prefix-a.json",
  JSON.stringify(rd().events.slice(0, n - 1).map((e) => ({ k: e.kind, s: e.step, st: e.status, key: e.key, at: e.at, p: e.provenance }))));
console.log("A-OK");
'
    assert_eq "M3/route-a-ok" "A-OK" "$NODE_OUT"
    nodejs "$SID_3B" "$PRE"'
S.markStep(sid, "review_security", "complete");
const n = rd().events.length;
const b = JSON.stringify(rd().events.slice(0, n - 1).map((e) => ({ k: e.kind, s: e.step, st: e.status, key: e.key, at: e.at, p: e.provenance })));
const a = fs.readFileSync(process.env.CLAUDE_WORKFLOW_DIR + "/prefix-a.json", "utf8");
console.log(a === b ? "IDENTICAL" : "DIFFER\nA=" + a + "\nB=" + b);
'
    assert_eq "M3/deterministic-prefix" "IDENTICAL" "$NODE_OUT"
fi

echo "== M4: persistMigratedState is fail-open when the lock cannot be taken =="
if run_case "M4/persist-fail-open"; then
    next_sid
    SID_4="$SID"
    seed_v1 "$SID_4" "ordering"
    nodejs "$SID_4" "$PRE"'
const os = require("os");
const before = raw();
fs.writeFileSync(sp() + ".lock", JSON.stringify({ pid: process.pid, host: os.hostname(), at: new Date().toISOString() }));
let verdict = "NO-THROW";
try { S.readState(sid); S.persistMigratedState(sid); } catch (e) { verdict = "THREW:" + (e && e.name); }
const after = raw();
fs.unlinkSync(sp() + ".lock");
// Read-path migration is fail-open: it must neither throw nor half-write the file.
console.log(verdict + " unchanged=" + (before === after) + " still_readable=" + (S.readState(sid) !== null));
'
    assert_eq "M4/persist-fail-open" "NO-THROW unchanged=true still_readable=true" "$NODE_OUT"
fi

finish "migration-concurrency"
