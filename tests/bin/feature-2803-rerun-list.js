#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/run-tests-baseline-evidence, bin/workflow/lib/run-tests-baseline-evidence.js
// Tags: TL2, bin, run-tests, rerun-list, hits, scope:issue-specific, input-version, cache-key
// #2803: `run-tests-baseline-evidence rerun-list --session <sid>` prints, one path per line,
// the latest run's failing tests plus the ids of its `worktree-change <id>` HIT lines, so
// SKILL.md can rerun just those. A HIT with no test id means only a full rerun is safe:
// exit 9. The command only reads state.
// #2688: `input-version --session <sid>` prints the branch-rerun cache key (64 hex digits, exit
// 0) in a fixture repo's cwd, and nothing with exit 1 when no merge base resolves.
// TL3 gap: input-version's cost on a real worktree with a large diff is not measured.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f2803-rerun-list");
const { check, eq, show, seed, status, note } = F;
const CLI = "bin/workflow/run-tests-baseline-evidence";

const A = "tests/hooks/a.js";
const B = "tests/hooks/b.js";
const C = "tests/hooks/c.js";
const wcd = (id) => `worktree-change ${id} tree=/x kind=tracked paths=a.txt`;

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

let n = 0;
// A session whose latest run failed with `failing` and recorded `hits`.
function failedRun(failing, hits) {
  const sid = `s-2803-rl-${++n}`;
  F.seedPrefix(sid);
  seed(sid, [
    status("run_tests", "pending"),
    note("last_run_failed", true),
    note("last_exit_code", 1),
    note("run_outcome", "fail"),
    note("failing_tests", failing),
    note("hit_count", hits.length),
    note("hit_summary", hits),
  ]);
  return sid;
}

const lines = (stdout) => stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
const rerunList = (sid) => F.run(CLI, ["rerun-list", "--session", sid]);

caseBegin("rerun-list-prints-failing-tests-and-hit-ids", "bin/workflow/run-tests-baseline-evidence");
test("rerun-list-prints-failing-tests-and-hit-ids", () => noNewFailures(fails, () => {
  const sid = failedRun([A, B], [wcd(C)]);
  const before = F.eventCount(sid);
  const r = rerunList(sid);
  check("#2803: rerun-list exits 0 when every HIT names a test", () => {
    eq(r.status, 0, `exit (stderr ${show(r.stderr)})`);
  });
  check("#2803: rerun-list prints the failing tests and the worktree-change ids, one per line", () => {
    eq(lines(r.stdout).slice().sort(), [A, B, C], "paths");
  });
  check("#2803: rerun-list writes nothing to state", () => {
    eq(F.eventCount(sid), before, "event count");
  });

  const dup = failedRun([A], [wcd(A)]);
  const d = rerunList(dup);
  check("#2803: a test both failing and HIT is listed once", () => {
    eq(d.status, 0, "exit");
    eq(lines(d.stdout), [A], "paths");
  });

  const hitsOnly = failedRun([], [wcd(B)]);
  const h = rerunList(hitsOnly);
  check("#2803: a run that failed only on an attributed HIT lists the HIT id", () => {
    eq(h.status, 0, "exit");
    eq(lines(h.stdout), [B], "paths");
  });
}));
caseEnd();

caseBegin("rerun-list-exits-9-on-a-hit-without-a-test-id", "bin/workflow/run-tests-baseline-evidence");
test("rerun-list-exits-9-on-a-hit-without-a-test-id", () => noNewFailures(fails, () => {
  for (const [label, hit] of [
    ["command-guard", "command-guard (no test id) gh --version"],
    ["root-decoy", "root-decoy (no test id) /home/u/.claude/agents"],
    ["worktree-change", "worktree-change (no test id) tree=/x kind=tracked paths=a.txt"],
  ]) {
    const sid = failedRun([A], [wcd(B), hit]);
    const before = F.eventCount(sid);
    const r = rerunList(sid);
    check(`#2803: a ${label} HIT with no test id exits 9 (full rerun)`, () => {
      eq(r.status, 9, `exit (stdout ${show(r.stdout)} stderr ${show(r.stderr)})`);
    });
    check(`#2803: the ${label} exit 9 writes nothing to state`, () => {
      eq(F.eventCount(sid), before, "event count");
    });
  }
}));
caseEnd();

caseBegin("rerun-list-requires-a-session", "bin/workflow/run-tests-baseline-evidence");
test("rerun-list-requires-a-session", () => noNewFailures(fails, () => {
  const r = F.run(CLI, ["rerun-list"]);
  check("#2803: rerun-list without --session is a usage error (exit 2)", () => {
    eq(r.status, 2, "exit");
  });
  const known = F.run(CLI, ["rerun-list", "--session", "s-2803-none"]);
  check("#2803: rerun-list is a known subcommand (no 'unknown subcommand' usage error)", () => {
    if (/unknown subcommand/.test(known.stderr)) return `stderr ${show(known.stderr)}`;
    return undefined;
  });
}));
caseEnd();

// #2688 input-version: main@base, feature@head (one extra commit), run from the repo's cwd.
let ivRepo = null;
function inputVersionRepo() {
  if (ivRepo) return ivRepo;
  ivRepo = F.makeRepo("iv-repo", { "tests/bin/t.sh": "#!/usr/bin/env bash\nexit 0\n" }, { topic: "feature" });
  F.writeFiles(ivRepo, { "head.txt": "head\n" });
  F.git(ivRepo, ["add", "-A"]);
  F.git(ivRepo, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "head"]);
  return ivRepo;
}
const inputVersion = (branches) => {
  const r = F.run(CLI, ["input-version", "--session", `iv-${process.pid}`],
    { cwd: inputVersionRepo(), env: { DEFAULT_BRANCHES: branches }, timeout: 30000 });
  return { status: r.status, out: r.stdout.trim(), err: r.stderr };
};

caseBegin("input-version-prints-a-digest", "bin/workflow/run-tests-baseline-evidence");
test("input-version-prints-a-digest", () => noNewFailures(fails, () => {
  const a = inputVersion("main");
  check("#2688: input-version prints 64 hex digits and exits 0", () => {
    eq(a.status, 0, `exit (stderr ${show(a.err)})`);
    if (!/^[0-9a-f]{64}$/.test(a.out)) return `stdout ${show(a.out)}`;
    return undefined;
  });
  check("#2688: the same tree gives the same digest", () => {
    if (a.out === "") return "first run printed no digest";
    eq(inputVersion("main").out, a.out, "digest");
    return undefined;
  });
  F.writeFiles(inputVersionRepo(), { "head.txt": "changed\n" });
  const b = inputVersion("main");
  check("#2688: an uncommitted change moves the digest", () => {
    eq(b.status, 0, `exit (stderr ${show(b.err)})`);
    if (b.out === a.out) return `digest unchanged ${show(b.out)}`;
    return undefined;
  });
}));
caseEnd();

caseBegin("input-version-null-exits-1", "bin/workflow/run-tests-baseline-evidence");
test("input-version-null-exits-1", () => noNewFailures(fails, () => {
  const r = inputVersion("nonexistent-2688");
  check("#2688: with no merge base input-version prints nothing and exits 1", () => {
    eq(r.status, 1, `exit (stderr ${show(r.err)})`);
    eq(r.out, "", "stdout");
  });
}));
caseEnd();
