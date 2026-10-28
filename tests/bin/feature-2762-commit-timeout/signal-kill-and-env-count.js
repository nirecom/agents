"use strict";
// Signal-kill and staged-count parts of tests/bin/feature-2762-commit-timeout.js (#2762). Hold no
// case markers; the entrypoint wraps each run function in one and hands over its fixtures as F.
// spawn.js reports timedOut for any signal kill (external kill, maxBuffer overflow), so the commit
// step must also see the elapsed time reach the limit before it reports commit_timeout.
const assert = require("node:assert");
const { test } = require("node:test");
// Frozen clocks make the elapsed time runGit measures exactly the fake jump.
const { withFrozenClocks: withFrozenClock } = require("./fake-clock");

const COUNT_ARGV = "diff --cached --name-only -z";
const FLOOR_LINE = "staged files could not be counted";

const killed = (signal, stderr) => ({ status: null, signal, timedOut: true, spawnError: null, stdout: "", stderr: stderr || "" });
const countCalls = (r) => r.calls.filter((c) => c.command === "git" && c.args.join(" ") === COUNT_ARGV);

function runSignalKill(F) {
  test("C1-a: a signal kill 2 s into a 300 s limit is a generic commit failure naming the signal", () => {
    for (const signal of ["SIGTERM", "SIGKILL"]) {
      const r = withFrozenClock(() => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME,
        commit: killed(signal), commitElapsedMs: 2000 }));
      assert.strictEqual(r.commitCall.timeoutMs, 300000, signal);
      assert.strictEqual(r.res.status, "staging_check_failed", `${signal}: ${r.res.summary}`);
      assert.ok(r.res.summary.startsWith("git commit failed:"), `${signal}: ${r.res.summary}`);
      assert.ok(r.res.summary.includes(signal), `${signal}: the summary names the signal: ${r.res.summary}`);
      assert.ok(!r.res.summary.includes("timed out"), `${signal}: ${r.res.summary}`);
      assert.ok(!r.logBody.includes("after the commit timeout"), `${signal}: the after-timeout probes must not run`);
      assert.deepStrictEqual(r.pushCalls, [], `${signal}: no push`);
    }
  });
  test("C1-c: a signal kill with stderr text still names the signal", () => {
    const r = withFrozenClock(() => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME,
      commit: killed("SIGTERM", "pre-commit-section: outbound-scan\nsome hook chatter\n"), commitElapsedMs: 2000 }));
    assert.strictEqual(r.res.status, "staging_check_failed", r.res.summary);
    assert.ok(r.res.summary.includes("SIGTERM"), r.res.summary);
  });
  test("C1-b: a timed-out commit whose elapsed time equals or passes the limit is commit_timeout", () => {
    for (const elapsed of [300000, 300001, 301000]) {
      const r = withFrozenClock(() => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME,
        commit: F.timedOut(F.MARKERS), commitElapsedMs: elapsed }));
      assert.strictEqual(r.res.status, "commit_timeout", `elapsed=${elapsed}: ${r.res.summary}`);
      assert.ok(r.res.summary.includes("(limit 300s from 1 staged files)"), `elapsed=${elapsed}: ${r.res.summary}`);
      assert.deepStrictEqual(r.pushCalls, [], `elapsed=${elapsed}: no push`);
    }
  });
  runWallClockStep(F);
  runMarkerSkip(F);
}

// The elapsed time is monotonic: a wall clock (Date.now) step during the commit changes neither
// verdict. Backwards must not hide a real timeout; forwards must not turn an early kill into one.
function runWallClockStep(F) {
  test("C1-d: a commit at its limit while the wall clock steps back an hour is still commit_timeout", () => {
    const r = withFrozenClock(() => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME,
      commit: F.timedOut(F.MARKERS), commitElapsedMs: 301000, commitWallJumpMs: -3600000 }));
    assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
    assert.ok(r.res.summary.startsWith("git commit timed out after 301s (limit 300s from 1 staged files)"), r.res.summary);
    assert.deepStrictEqual(r.pushCalls, [], "no push");
  });
  test("C1-e: an early signal kill while the wall clock leaps a day ahead is not commit_timeout", () => {
    for (const signal of ["SIGTERM", "SIGKILL"]) {
      const r = withFrozenClock(() => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME,
        commit: killed(signal), commitElapsedMs: 2000, commitWallJumpMs: 86400000 }));
      assert.strictEqual(r.res.status, "staging_check_failed", `${signal}: ${r.res.summary}`);
      assert.ok(r.res.summary.startsWith("git commit failed:"), `${signal}: ${r.res.summary}`);
      assert.ok(r.res.summary.includes(signal), `${signal}: the summary names the signal: ${r.res.summary}`);
      assert.deepStrictEqual(r.pushCalls, [], `${signal}: no push`);
    }
  });
}

// The failure detail skips whole pre-commit section marker lines (lastSectionMarker's format).
const failCommit = (F, commit) => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME, commit });

function runMarkerSkip(F) {
  test("C3-a: an ordinary pre-commit failure names the hook's reason, not a section marker", () => {
    for (const eol of ["\n", "\r\n"]) {
      const stderr = ["pre-commit-section: outbound-scan", "pre-commit-section: secrets", "ERROR: secret found in foo.txt", ""].join(eol);
      const r = failCommit(F, F.err(1, stderr));
      assert.strictEqual(r.res.status, "staging_check_failed", JSON.stringify(eol));
      assert.strictEqual(r.res.summary, "git commit failed: ERROR: secret found in foo.txt", JSON.stringify(eol));
      assert.ok(!r.res.summary.includes("pre-commit-section:"), r.res.summary);
      assert.deepStrictEqual(r.pushCalls, [], "no push");
    }
  });
  test("C3-b: stderr holding only section markers and blank lines falls back to the exit status", () => {
    const stderr = "pre-commit-section: outbound-scan\n\npre-commit-section: agents-repo-gate-check-x\n  \n";
    const r = failCommit(F, F.err(1, stderr));
    assert.strictEqual(r.res.status, "staging_check_failed", r.res.summary);
    assert.strictEqual(r.res.summary, "git commit failed: exit 1");
  });
  test("C3-c: an early signal kill names the signal and the first non-marker line", () => {
    const r = withFrozenClock(() => F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: F.SAME,
      commit: killed("SIGKILL", "pre-commit-section: outbound-scan\nfatal: interrupted\n"), commitElapsedMs: 2000 }));
    assert.strictEqual(r.res.status, "staging_check_failed", r.res.summary);
    assert.ok(r.res.summary.includes("SIGKILL"), r.res.summary);
    assert.ok(r.res.summary.includes("fatal: interrupted"), r.res.summary);
    assert.ok(!r.res.summary.includes("pre-commit-section:"), r.res.summary);
  });
  test("C3-d: a line that only mentions the marker phrase mid-line is kept as the detail", () => {
    const line = "error: pre-commit-section: is not a valid name";
    const r = failCommit(F, F.err(1, `pre-commit-section: outbound-scan\n${line}\n`));
    assert.strictEqual(r.res.summary, `git commit failed: ${line}`);
  });
}

function runStagedCount(F) {
  test("C2-a: a valid COMMIT_TIMEOUT_SECS skips the staged-file count", () => {
    const r = F.runProcedure({ env: "COMMIT_TIMEOUT_SECS=900\n", names: F.err(128, "fatal"), headBefore: F.SAME, headAfter: F.OTHER, commit: F.ok("") });
    assert.deepStrictEqual(countCalls(r), [], `no ${COUNT_ARGV} call with a valid setting`);
    assert.ok(!r.logBody.includes(FLOOR_LINE), r.logBody);
    assert.strictEqual(r.commitCall.timeoutMs, 900000);
    assert.ok(r.logBody.includes("commit timeout limit: 900s (env)"), r.logBody);
  });
  test("C2-b: no COMMIT_TIMEOUT_SECS counts the staged files", () => {
    const r = F.runProcedure({ env: "", names: F.NAMES_208, headBefore: F.SAME, headAfter: F.OTHER, commit: F.ok("") });
    assert.strictEqual(countCalls(r).length, 1);
    assert.strictEqual(r.commitCall.timeoutMs, 1040000);
  });
  test("C2-c: an invalid COMMIT_TIMEOUT_SECS counts the staged files and logs the invalid value", () => {
    for (const raw of ["0900", "abc"]) {
      const r = F.runProcedure({ env: `COMMIT_TIMEOUT_SECS=${raw}\n`, names: F.NAMES_208, headBefore: F.SAME, headAfter: F.OTHER, commit: F.ok("") });
      assert.strictEqual(countCalls(r).length, 1, raw);
      assert.strictEqual(r.commitCall.timeoutMs, 1040000, raw);
      assert.ok(r.logBody.includes(`COMMIT_TIMEOUT_SECS='${raw}' is not a valid value`), `${raw}: ${r.logBody}`);
    }
  });
}

module.exports = { runSignalKill, runStagedCount };
