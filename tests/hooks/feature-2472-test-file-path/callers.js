"use strict";
// Tests: hooks/workflow-gate/staged-evidence.js
// Tags: TL2, hooks, write-tests, completion-evidence, commit-gate, scope:issue-specific
// #2472 T5: the write_tests evidence predicate gives one answer through every caller — the
// commit-gate-steps bypass, effective-state's staged-only resolution, and the committed
// (post-merge) fallback. Only non-test files under tests/ is no evidence; a test file or a
// test helper under tests/ or test/ is.

const F = require("../../lib/run-tests-outcome-fixture");
const { check, eq, errText, mod, seed, status } = F;

const SETS = [
  { label: "only tests/x.md", files: { "tests/x.md": "# notes\n" }, want: false },
  { label: "only tests/fixtures/a.json", files: { "tests/fixtures/a.json": "{}\n" }, want: false },
  { label: "tests/hooks/x.sh", files: { "tests/hooks/x.sh": "#!/usr/bin/env bash\n" }, want: true },
  { label: "tests/hooks/foo/_lib.sh", files: { "tests/hooks/foo/_lib.sh": "# helper\n" }, want: true },
  { label: "test/x.sh", files: { "test/x.sh": "#!/usr/bin/env bash\n" }, want: true },
];

let n = 0;

// A repo with `files` staged on top of a base commit.
function stagedRepo(files) {
  const repo = F.makeRepo(`staged-${++n}`, {});
  F.writeFiles(repo, files);
  F.git(repo, ["add", "-A"]);
  return repo;
}

// A topic branch with `files` committed, origin/HEAD pointing at the base; nothing staged.
function committedRepo(files) {
  const repo = F.makeRepo(`committed-${++n}`, {});
  const base = F.git(repo, ["rev-parse", "HEAD"]);
  F.git(repo, ["update-ref", "refs/remotes/origin/main", base]);
  F.git(repo, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]);
  F.git(repo, ["checkout", "-q", "-b", "topic"]);
  F.writeFiles(repo, files);
  F.git(repo, ["add", "-A"]);
  F.git(repo, ["commit", "-q", "-m", "topic"]);
  return repo;
}

function commitGateBypass(repo) {
  const { isWriteTestsEvidenceBypassed } = mod("hooks/workflow-gate/commit-gate-steps.js");
  return isWriteTestsEvidenceBypassed({ steps: { write_tests: { status: "skipped" } } }, [], repo);
}

function effectiveStagedOnly(repo) {
  const sid = `s-2472-eff-${++n}`;
  F.seedPrefix(sid);
  seed(sid, [status("write_tests", "pending")]);
  const wf = mod("hooks/workflow-state");
  const eff = mod("hooks/workflow-state/effective-state.js").reconcileEffectiveState(wf.readState(sid), sid, {
    repoDir: repo, evidencePolicy: "staged-only", resolveAll: true,
  });
  return eff.steps.write_tests.status === "complete";
}

function committedFallback(repo) {
  const sid = `s-2472-committed-${++n}`;
  return mod("hooks/workflow-state/evidence-resolver.js").hasCompletionEvidence("write_tests", sid, { repoDir: repo }) === true;
}

function everyCallerAgrees() {
  for (const set of SETS) {
    const got = {};
    for (const [name, build, ask] of [
      ["commit-gate-steps bypass", stagedRepo, commitGateBypass],
      ["effective-state staged-only", stagedRepo, effectiveStagedOnly],
      ["committed fallback", committedRepo, committedFallback],
    ]) {
      try {
        got[name] = ask(build(set.files));
      } catch (e) {
        got[name] = `error: ${errText(e)}`;
      }
      check(`T5: ${name} — ${set.label} ${set.want ? "is" : "is not"} write_tests evidence`, () => {
        eq(got[name], set.want, name);
        return undefined;
      });
    }
  }
}

module.exports = { everyCallerAgrees };
