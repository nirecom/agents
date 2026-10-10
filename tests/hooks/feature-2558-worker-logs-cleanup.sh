#!/usr/bin/env bash
# tests/hooks/feature-2558-worker-logs-cleanup.sh
# Tests: hooks/workflow-state/state-io/zombie-cleanup.js, hooks/workflow-state/state-io/control-dir.js
# Tags: worker-dispatch, worker-log, zombie-cleanup, retention, symlink, security, TL2, scope:issue-specific
#
# Issue #2558 — <WF>/worker-logs/ holds sid-less worker logs. cleanupZombies drops
# its direct regular files after 30 days, keeps the dir and its subdirs, and never
# follows a symlink (neither an entry inside nor worker-logs itself).
# TL3 gap: host mtime granularity and a real session-end sweep are not exercised.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
CLEANUP_LIB="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io/zombie-cleanup.js"
CONTROL_LIB="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io/control-dir.js"

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

BASE="$(make_tmp)"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/plans"
PLANS="$(np "$BASE/plans")"
cd "$BASE" || exit 1

# drive <scenario> <wf-dir> — builds the fixture, runs the real cleanupZombies(7),
# and prints one "<probe>=<value>" line per observation.
drive() {
    mkdir -p "$2"
    run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID "WORKFLOW_STATE_DIR=$(np "$2")" "WORKFLOW_PLANS_DIR=$PLANS" \
        node - "$(np "$CLEANUP_LIB")" "$(np "$CONTROL_LIB")" "$1" "$(np "$2")" 2>&1 <<'JS'
const fs = require("fs"); const path = require("path");
const [cleanupLib, controlLib, scenario, wf] = process.argv.slice(-4);
const DAY = 86400 * 1000;
const age = (p, days, link) => { const t = new Date(Date.now() - days * DAY); (link ? fs.lutimesSync : fs.utimesSync)(p, t, t); };
const put = (p, days) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, "x"); age(p, days); };
const has = (p) => { try { fs.lstatSync(p); return "yes"; } catch (e) { return "no"; } };
const isLink = (p) => { try { return fs.lstatSync(p).isSymbolicLink() ? "yes" : "no"; } catch (e) { return "missing"; } };
const link = (target, p, type) => { try { fs.symlinkSync(target, p, type); return true; } catch (e) { return false; } };
const logs = path.join(wf, "worker-logs"); const outside = path.join(wf, "..", scenario + "-outside");
if (scenario === "exports") {
  const z = require(cleanupLib); const c = require(controlLib);
  console.log("sweep=" + typeof z.sweepWorkerLogs);
  console.log("days=" + z.WORKER_LOG_RETENTION_DAYS);
  console.log("dirname=" + c.WORKER_LOGS_DIRNAME);
  console.log("getdir=" + (typeof c.getWorkerLogsDir === "function" && path.resolve(c.getWorkerLogsDir()) === path.resolve(wf, "worker-logs") ? "ok" : "bad"));
  console.log("assert=" + typeof c.assertRealControlDir);
  process.exit(0);
}
if (scenario === "retention") {
  put(path.join(logs, "old-31d.log"), 31); put(path.join(logs, "mid-10d.log"), 10); put(path.join(logs, "new-1d.log"), 1);
  put(path.join(logs, "sub", "deep-40d.log"), 40); age(path.join(logs, "sub"), 40);
  put(path.join(outside, "target-40d.txt"), 40);
  const ok = link(path.join(outside, "target-40d.txt"), path.join(logs, "lnk-40d"), "file");
  if (ok) age(path.join(logs, "lnk-40d"), 40, true);
  console.log("symlink=" + (ok ? "ok" : "unavailable"));
}
if (scenario === "emptied") { put(path.join(logs, "only-60d.log"), 60); }
if (scenario === "linked-dir") {
  put(path.join(outside, "victim-60d.log"), 60);
  console.log("symlink=" + (link(outside, logs, "dir") ? "ok" : "unavailable"));
}
if (scenario === "boundary") { put(path.join(logs, "edge-under.log"), 30 - 1 / 24); put(path.join(logs, "edge-over.log"), 30 + 1 / 24); }
if (scenario === "idempotent") { put(path.join(logs, "idem-old.log"), 60); put(path.join(logs, "idem-new.log"), 1); }
const runOnce = () => { try { require(cleanupLib).cleanupZombies(7); return "ok"; } catch (e) { return "threw:" + e.message; } };
console.log("run1=" + runOnce());
if (scenario === "idempotent") console.log("run2=" + runOnce());
for (const n of ["old-31d.log", "mid-10d.log", "new-1d.log", "only-60d.log", "sub", "lnk-40d", "edge-under.log", "edge-over.log", "idem-old.log", "idem-new.log"]) console.log(n + "=" + has(path.join(logs, n)));
console.log("sub-content=" + has(path.join(logs, "sub", "deep-40d.log")));
console.log("logs-dir=" + has(logs));
console.log("logs-is-link=" + isLink(logs));
console.log("outside-target=" + has(path.join(outside, "target-40d.txt")));
console.log("outside-victim=" + has(path.join(outside, "victim-60d.log")));
JS
}

case_begin "control-dir-names-worker-logs" "hooks/workflow-state/state-io/control-dir.js"
out="$(drive exports "$BASE/wf-exports")"
assert_eq "exports/WORKER_LOGS_DIRNAME" "worker-logs" "$(kv "$out" dirname)"
assert_eq "exports/getWorkerLogsDir-under-workflow-dir" "ok" "$(kv "$out" getdir)"
assert_eq "exports/assertRealControlDir-exported" "function" "$(kv "$out" assert)"
case_end

case_begin "zombie-cleanup-sweeps-worker-logs" "hooks/workflow-state/state-io/zombie-cleanup.js"
assert_eq "exports/sweepWorkerLogs" "function" "$(kv "$out" sweep)"
assert_eq "exports/WORKER_LOG_RETENTION_DAYS" "30" "$(kv "$out" days)"

out="$(drive retention "$BASE/wf-retention")"
assert_eq "retention/31-day-log-removed" "no" "$(kv "$out" old-31d.log)"
assert_eq "retention/10-day-log-kept" "yes" "$(kv "$out" mid-10d.log)"
assert_eq "retention/1-day-log-kept" "yes" "$(kv "$out" new-1d.log)"
assert_eq "retention/subdir-kept" "yes" "$(kv "$out" sub)"
assert_eq "retention/subdir-content-kept" "yes" "$(kv "$out" sub-content)"
if [ "$(kv "$out" symlink)" = "ok" ]; then
    assert_eq "retention/symlink-entry-left-alone" "yes" "$(kv "$out" lnk-40d)"
    assert_eq "retention/symlink-target-untouched" "yes" "$(kv "$out" outside-target)"
else
    skip "retention/symlink-entry (native symlinks unavailable)"
fi

out="$(drive emptied "$BASE/wf-emptied")"
assert_eq "emptied/old-log-removed" "no" "$(kv "$out" only-60d.log)"
assert_eq "emptied/dir-itself-kept" "yes" "$(kv "$out" logs-dir)"

out="$(drive linked-dir "$BASE/wf-linked")"
if [ "$(kv "$out" symlink)" = "ok" ]; then
    assert_eq "linked-dir/not-followed" "yes" "$(kv "$out" outside-victim)"
    assert_eq "linked-dir/link-kept" "yes" "$(kv "$out" logs-is-link)"
else
    skip "linked-dir (native symlinks unavailable)"
fi

out="$(drive boundary "$BASE/wf-boundary")"
assert_eq "boundary/run-ok" "ok" "$(kv "$out" run1)"
assert_eq "boundary/just-under-30d-kept" "yes" "$(kv "$out" edge-under.log)"
assert_eq "boundary/just-over-30d-removed" "no" "$(kv "$out" edge-over.log)"

out="$(drive idempotent "$BASE/wf-idempotent")"
assert_eq "idempotent/first-sweep-ok" "ok" "$(kv "$out" run1)"
assert_eq "idempotent/second-sweep-ok" "ok" "$(kv "$out" run2)"
assert_eq "idempotent/old-log-removed" "no" "$(kv "$out" idem-old.log)"
assert_eq "idempotent/new-log-survives-both" "yes" "$(kv "$out" idem-new.log)"
assert_eq "idempotent/dir-kept" "yes" "$(kv "$out" logs-dir)"

out="$(drive missing "$BASE/wf-missing")"
assert_eq "missing/no-worker-logs-dir-no-throw" "ok" "$(kv "$out" run1)"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
