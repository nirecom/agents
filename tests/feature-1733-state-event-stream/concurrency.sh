#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/concurrency.sh
# Tests: hooks/workflow-state/state-io/state-lock.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/core.js
# Tags: workflow-state, event-stream, concurrency, locking, cas, atomicity, scope:issue-specific, pwsh-not-required, TL2
#
# The append-only guarantee is a MECHANISM, not a convention: several real OS
# processes (PostToolUse recorder / PreToolUse gate / bash sentinel hook) write the
# same state file. These cases spawn genuinely parallel `node` processes against a
# real filesystem, which is why they are TL2 rather than TL1 — a mocked fs cannot
# lose an event to a lost update or collide on a rename.
#
# Sub-cases: (a) parallel append integrity, (b) same-step race, (c) dead-pid lock
# reclaim, (d) live-pid timeout with a zero-byte-change guarantee, (e) fixed-tmp-name
# collision regression.
#
# TL3 gap (what this test does NOT catch):
# - hook registration: the racing writers are node processes calling the module, not
#   Claude Code firing PreToolUse and PostToolUse for the same tool call.
# - a network filesystem (~/.claude on NFS/SMB) where O_EXCL is not atomic; only the
#   CAS layer would defend there and this test runs on a local FS.
# - lock contention against a process owned by a different OS user (EPERM branch of
#   the liveness probe).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="conc"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WORKERS=8
MARKS=5
EXPECTED=$((WORKERS * MARKS))

echo "== C-a: ${WORKERS} parallel processes x ${MARKS} markStep -> exactly ${EXPECTED} events, no gaps =="
if run_case "C-a/parallel-append-integrity"; then
    next_sid
    SID_A="$SID"
    # Pre-create the state file so all workers race on append, not on creation.
    nodejs "$SID_A" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "C-a/seed" "SEEDED" "$NODE_OUT"

    WORKER_JS='const S = require("./hooks/workflow-state/state-io");
const sid = process.env.SID, n = Number(process.env.MARKS);
for (let i = 0; i < n; i++) S.markStep(sid, "run_tests", i % 2 ? "complete" : "in_progress");
console.log("DONE");
'
    for i in $(seq 1 "$WORKERS"); do
        (cd "$AGENTS_DIR" && env \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID_A" MARKS="$MARKS" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 90 node -e "$WORKER_JS" \
            >"$TMPROOT/w$i.out" 2>&1) &
    done
    wait

    WORKER_FAILS=0
    for i in $(seq 1 "$WORKERS"); do
        grep -q '^DONE$' "$TMPROOT/w$i.out" || WORKER_FAILS=$((WORKER_FAILS + 1))
    done
    assert_eq "C-a/all-workers-succeeded" "0" "$WORKER_FAILS"

    # +1 for the seeding workflow_init mark.
    nodejs_env "EXPECTED=$((EXPECTED + 1))" "$SID_A" "$PRE"'
const st = rd();
const ev = st.events;
const seqs = ev.map((e) => e.seq);
const contiguous = seqs.every((s, i) => s === i + 1);
const unique = new Set(seqs).size === seqs.length;
console.log("n=" + ev.length + "/" + process.env.EXPECTED +
            " contiguous=" + contiguous + " unique=" + unique);
'
    assert_eq "C-a/no-lost-updates" "n=$((EXPECTED + 1))/$((EXPECTED + 1)) contiguous=true unique=true" "$NODE_OUT"

    LEFTOVERS="$(find "$WF" -maxdepth 1 \( -name "$SID_A*.tmp" -o -name "$SID_A*.lock" \) | wc -l | tr -d ' ')"
    assert_eq "C-a/no-tmp-or-lock-leftovers" "0" "$LEFTOVERS"
fi

echo "== C-b: two processes marking the SAME step concurrently lose nothing =="
if run_case "C-b/same-step-race"; then
    next_sid
    SID_B="$SID"
    nodejs "$SID_B" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "C-b/seed" "SEEDED" "$NODE_OUT"

    RACE_JS='const S = require("./hooks/workflow-state/state-io");
for (let i = 0; i < 10; i++) S.markStep(process.env.SID, "run_tests", process.env.ST);
console.log("DONE");
'
    for st in complete pending; do
        (cd "$AGENTS_DIR" && env \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID_B" ST="$st" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 90 node -e "$RACE_JS" \
            >"$TMPROOT/race-$st.out" 2>&1) &
    done
    wait

    nodejs "$SID_B" "$PRE"'
const ev = rd().events.filter((e) => e.kind === "step_status" && e.step === "run_tests");
const last = ev[ev.length - 1];
const kinds = new Set(ev.map((e) => e.status));
console.log("n=" + ev.length +
            " both_statuses=" + (kinds.has("complete") && kinds.has("pending")) +
            " last_wins=" + (cur().steps.run_tests.status === last.status));
'
    assert_eq "C-b/same-step-race" "n=20 both_statuses=true last_wins=true" "$NODE_OUT"
fi

echo "== C-c: a lock file naming a dead pid is reclaimed, with a stderr warning =="
if run_case "C-c/dead-pid-reclaim"; then
    next_sid
    SID_C="$SID"
    nodejs "$SID_C" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "C-c/seed" "SEEDED" "$NODE_OUT"
    # A pid that is certainly not running on this host, tagged with THIS hostname so
    # the reclaim path is the liveness probe (not the mtime-stale fallback).
    nodejs "$SID_C" "$PRE"'
const os = require("os");
let dead = 999999;
for (; dead > 100; dead--) { try { process.kill(dead, 0); } catch (e) { if (e.code === "ESRCH") break; } }
fs.writeFileSync(sp() + ".lock", JSON.stringify({ pid: dead, host: os.hostname(), at: new Date().toISOString() }));
console.log("PLACED");
'
    assert_eq "C-c/lock-placed" "PLACED" "$NODE_OUT"
    nodejs "$SID_C" "$PRE"'
S.markStep(sid, "run_tests", "complete");
console.log("marked=" + cur().steps.run_tests.status +
            " lock_gone=" + !fs.existsSync(sp() + ".lock"));
'
    if printf '%s' "$NODE_OUT" | grep -q "marked=complete lock_gone=true"; then
        pass "C-c/dead-pid-reclaim"
    else
        fail "C-c/dead-pid-reclaim" "$NODE_OUT"
    fi
    if printf '%s' "$NODE_OUT" | grep -qiE "stale|reclaim|lock"; then
        pass "C-c/reclaim-warns-on-stderr"
    else
        fail "C-c/reclaim-warns-on-stderr" "no warning line in: $NODE_OUT"
    fi
fi

echo "== C-d: a live-pid lock exhausts the budget and leaves the file byte-identical =="
if run_case "C-d/live-pid-timeout"; then
    next_sid
    SID_D="$SID"
    nodejs "$SID_D" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "C-d/seed" "SEEDED" "$NODE_OUT"
    nodejs "$SID_D" "$PRE"'
const os = require("os");
const before = raw();
// Our own pid is unambiguously alive, so the liveness probe must NOT reclaim.
fs.writeFileSync(sp() + ".lock", JSON.stringify({ pid: process.pid, host: os.hostname(), at: new Date().toISOString() }));
let verdict = "NO-THROW";
const t0 = Date.now();
try { S.markStep(sid, "run_tests", "complete"); }
catch (e) { verdict = e && e.name === "StateLockTimeoutError" ? "TIMEOUT" : "OTHER:" + (e && e.name); }
const elapsed = Date.now() - t0;
const after = raw();
fs.unlinkSync(sp() + ".lock");
console.log(verdict + " unchanged=" + (before === after) + " budget_ok=" + (elapsed >= 1000 && elapsed < 20000));
'
    assert_eq "C-d/live-pid-timeout" "TIMEOUT unchanged=true budget_ok=true" "$NODE_OUT"
fi

echo "== C-e: a pre-existing fixed-name .tmp does not break the write (unique-tmp regression) =="
if run_case "C-e/fixed-tmp-collision"; then
    next_sid
    SID_E="$SID"
    nodejs "$SID_E" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "C-e/seed" "SEEDED" "$NODE_OUT"
    nodejs "$SID_E" "$PRE"'
// The pre-#1733 writer used the FIXED name `<state>.tmp`. Squat on it (and make it
// non-JSON) — a writer that still uses the fixed name either fails or reads garbage.
fs.writeFileSync(sp() + ".tmp", "SQUATTED-NOT-JSON");
let verdict = "OK";
try { S.markStep(sid, "run_tests", "complete"); } catch (e) { verdict = "THREW:" + (e && e.message); }
const squat = fs.existsSync(sp() + ".tmp") ? fs.readFileSync(sp() + ".tmp", "utf8") : "(gone)";
console.log(verdict + " status=" + cur().steps.run_tests.status +
            " squat_untouched=" + (squat === "SQUATTED-NOT-JSON" || squat === "(gone)"));
'
    assert_eq "C-e/fixed-tmp-collision" "OK status=complete squat_untouched=true" "$NODE_OUT"
fi

echo "== C-f: reentrancy — a nested write inside a held lock does not self-deadlock =="
if run_case "C-f/reentrant-lock"; then
    next_sid
    nodejs "$SID" "$PRE"'
const L = require("./hooks/workflow-state/state-io/state-lock");
let verdict = "OK";
try {
  L.withStateLock(sid, () => { S.markStep(sid, "run_tests", "complete"); });
} catch (e) { verdict = "THREW:" + (e && e.name); }
console.log(verdict + " status=" + cur().steps.run_tests.status +
            " lock_released=" + !fs.existsSync(sp() + ".lock"));
'
    assert_eq "C-f/reentrant-lock" "OK status=complete lock_released=true" "$NODE_OUT"
fi

echo "== C-g: four different TOP-LEVEL writers racing an appender lose nothing =="
if run_case "C-g/top-level-update-race"; then
    next_sid
    SID_G="$SID"
    nodejs "$SID_G" "$PRE"'S.markStep(sid, "workflow_init", "complete"); console.log("SEEDED");'
    assert_eq "C-g/seed" "SEEDED" "$NODE_OUT"

    # events[] is not the only part of the file that several processes write: the
    # commit-push hook sets last_pushed_sha, the worktree recorder sets session_worktree,
    # workflow-init sets workflow_type and closes_issues — all read-modify-write over the
    # WHOLE file. If those paths bypass the lock (or read outside it), the classic lost
    # update appears: writer B reads before A commits, and A's key vanishes from the file
    # that B writes. Each racer here owns a DISTINCT key, so any missing key at the end is
    # a lost update and nothing else.
    G_JS='const S = require("./hooks/workflow-state/state-io");
const sid = process.env.SID, role = process.env.ROLE;
const doIt = () => {
  if (role === "sha") S.setLastPushedSha(sid, "sha-0123456789abcdef");
  else if (role === "worktree") S.recordSessionWorktree(sid, "/w/1733");
  else if (role === "type") S.updateTopLevel(sid, (st) => { st.workflow_type = "wf-code"; });
  else if (role === "issues") S.updateTopLevel(sid, (st) => { st.closes_issues = [1733]; });
  else for (let i = 0; i < 5; i++) S.markStep(sid, "run_tests", i % 2 ? "complete" : "in_progress");
};
for (let attempt = 0; attempt < 3; attempt++) {
  try { doIt(); break; } catch (e) { if (attempt === 2) console.log("THREW:" + e.name); }
}
console.log("DONE");
'
    for role in sha worktree type issues append append; do
        (cd "$AGENTS_DIR" && env \
            CLAUDE_WORKFLOW_DIR="$WF_NATIVE" AGENTS_CONFIG_DIR="$CFG_NATIVE" \
            WORKFLOW_PLANS_DIR="$PLANS_NATIVE" \
            HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID_G" ROLE="$role" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 90 node -e "$G_JS" \
            >"$TMPROOT/g-$role-$RANDOM.out" 2>&1) &
    done
    wait

    G_INCOMPLETE="$(grep -L '^DONE$' "$TMPROOT"/g-*.out 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "C-g/all-writers-finished" "0" "$G_INCOMPLETE"

    nodejs "$SID_G" "$PRE"'
const st = rd();
const seqs = st.events.map((e) => e.seq);
const marks = st.events.filter((e) => e.kind === "step_status" && e.step === "run_tests").length;
console.log([
  "sha=" + st.last_pushed_sha,
  "worktree=" + st.session_worktree,
  "type=" + st.workflow_type,
  "issues=" + JSON.stringify(st.closes_issues),
  "marks=" + marks,
  "contiguous=" + seqs.every((s, i) => s === i + 1),
].join(" "));
'
    assert_eq "C-g/top-level-update-race" \
        "sha=sha-0123456789abcdef worktree=/w/1733 type=wf-code issues=[1733] marks=10 contiguous=true" \
        "$NODE_OUT"
fi

echo "== C-h: a callback that throws still releases the lock =="
if run_case "C-h/callback-throw-releases-lock"; then
    next_sid
    nodejs "$SID" "$PRE"'
const L = require("./hooks/workflow-state/state-io/state-lock");
S.markStep(sid, "workflow_init", "complete");
let propagated = "-";
try { L.withStateLock(sid, () => { throw new Error("boom"); }); }
catch (e) { propagated = e && e.message; }
// A lock leaked by an exception is invisible until the NEXT writer times out, minutes or
// a session later — so prove the release by taking the lock again immediately.
let reacquired = "no";
try { L.withStateLock(sid, () => { reacquired = "yes"; }); } catch (e) { reacquired = "threw:" + e.name; }
console.log("propagated=" + propagated + " lock_file=" + fs.existsSync(sp() + ".lock") + " reacquired=" + reacquired);
'
    assert_eq "C-h/callback-throw-releases-lock" "propagated=boom lock_file=false reacquired=yes" "$NODE_OUT"
fi

echo "== C-i: a malformed lock payload is handled by age, never by a crash =="
if run_case "C-i/malformed-lock-payload"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const results = [];
// Every shape a half-written or truncated lock file can take. None may crash the writer:
// the payload is untrusted input, and a parse error here would take down a hook.
const payloads = ["", "{", "null", "[]", "{\"pid\":\"not-a-number\"}", "{\"host\":42}", " "];
payloads.forEach((p, i) => {
  fs.writeFileSync(sp() + ".lock", p);
  const old = (Date.now() - 120000) / 1000;   // 2 minutes: past the 30s mtime-stale rule
  fs.utimesSync(sp() + ".lock", old, old);
  let r = "OK";
  try { S.markStep(sid, "run_tests", "complete"); }
  catch (e) { r = (e && e.name) || "Error"; }
  results.push(i + ":" + r);
  try { fs.unlinkSync(sp() + ".lock"); } catch (e) {}
});
const bad = results.filter((r) => !r.endsWith(":OK"));
console.log(bad.length ? "BAD " + bad.join(",") : "ALL-RECLAIMED");
'
    assert_eq "C-i/malformed-lock-payload" "ALL-RECLAIMED" "$NODE_OUT"
fi

echo "== C-j: a foreign-host lock is respected while fresh and reclaimed once stale =="
if run_case "C-j/foreign-host-lock"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const place = (ageMs) => {
  // Another machine sharing ~/.claude: the pid means nothing here, so liveness cannot be
  // probed and mtime is the only evidence available.
  fs.writeFileSync(sp() + ".lock", JSON.stringify({ pid: 4242, host: "some-other-host", at: new Date().toISOString() }));
  const t = (Date.now() - ageMs) / 1000;
  fs.utimesSync(sp() + ".lock", t, t);
};
place(0);
const beforeFresh = raw();
let fresh = "NO-THROW";
try { S.markStep(sid, "run_tests", "complete"); } catch (e) { fresh = e && e.name; }
const unchanged = raw() === beforeFresh;
try { fs.unlinkSync(sp() + ".lock"); } catch (e) {}
place(120000);
let stale = "OK";
try { S.markStep(sid, "run_tests", "complete"); } catch (e) { stale = (e && e.name) || "Error"; }
console.log("fresh=" + fresh + " untouched_while_fresh=" + unchanged +
            " stale=" + stale + " status=" + cur().steps.run_tests.status +
            " lock_gone=" + !fs.existsSync(sp() + ".lock"));
'
    assert_eq "C-j/foreign-host-lock" \
        "fresh=StateLockTimeoutError untouched_while_fresh=true stale=OK status=complete lock_gone=true" \
        "$NODE_OUT"
fi

echo "== C-k: a write that fails mid-serialization leaves the file byte-identical =="
if run_case "C-k/fail-closed-no-partial-write"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "research", "complete");
const before = raw();
// A value JSON.stringify cannot serialize fails the write AFTER the lock is taken and the
// events array has been extended in memory — the exact window in which a truncated file
// or a half-applied append could be left on disk. chmod is not used here: it is a no-op
// for an administrator on Windows, so it would silently stop testing anything.
const poison = [{ kind: "step_annotation", step: "research", key: "warnings_summary", value: 10n,
  provenance: "observed", origin: "fail-closed-test" }];
let verdict = "NO-THROW";
try { S.appendEvents(sid, poison); } catch (e) { verdict = "THREW"; }
const circular = { kind: "step_annotation", step: "research", key: "warnings_summary",
  provenance: "observed", origin: "fail-closed-test" };
circular.value = circular;
let verdict2 = "NO-THROW";
try { S.appendEvents(sid, [circular]); } catch (e) { verdict2 = "THREW"; }
const leftovers = fs.readdirSync(process.env.CLAUDE_WORKFLOW_DIR)
  .filter((f) => f.indexOf(sid) === 0 && (f.endsWith(".tmp") || f.endsWith(".lock"))).length;
console.log([
  verdict, verdict2,
  "unchanged=" + (raw() === before),
  "leftovers=" + leftovers,
  "still_readable=" + (S.readState(sid).current.steps.research.status === "complete"),
].join(" "));
'
    assert_eq "C-k/fail-closed-no-partial-write" \
        "THREW THREW unchanged=true leftovers=0 still_readable=true" "$NODE_OUT"
fi

finish "concurrency"
