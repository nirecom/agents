"use strict";
// Tests: bin/check-test-frontmatter.sh, bin/check-case-markers.sh, bin/check-test-language-match.sh, bin/check-self-impl.sh, bin/check-test-frontmatter/cli.js, bin/check-case-markers/cli.js, bin/check-test-language-match/cli.js, bin/check-self-impl/cli.js, hooks/lib/test-gates/placement.js, hooks/lib/test-gates/headers.js, hooks/lib/test-gates/case-records.js, hooks/lib/test-gates/self-impl.js, hooks/lib/test-gates/code-language.js, hooks/lib/test-gates/parts/bash-case-embed.js, hooks/lib/test-gates/parts/external-runtime.js, hooks/lib/test-gates/frontmatter.js, hooks/lib/test-gates/case-markers.js, hooks/block-case-markers.js, bin/lib/test-language-parts/pester.sh
// Tags: TL1, TL2, bin, golden, parity, table-driven, test-lang-exception:symmetry, scope:issue-specific
// #2507 S4: the four test-gate CLIs move to Node. golden/cli.json holds what the bash CLIs print
// on the corpus (generate-golden.js, LC_ALL=C.UTF-8). The bin/ .sh runs match it (green now;
// after the port they go through the adapter), run() of each Node cli.js must print the same
// bytes, and the modules answer as the bash parts they port (D7 parity). noNode runs pin rc 2
// only: the message names the missing piece, which the port changes.
// pester / pytest conforming runs run live (runtime-readers-cases.js), skipped when pwsh / uv is absent.
// TL3 gap: on a host where node shares a directory with bash / git, noNode runs are reported, not run.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");

// First: patches child_process before any gate module loads (they are required inside tests).
const R = require("./feature-2507-test-gates-node/runtime-readers-cases");
const F = require("./feature-2507-test-gates-node/fixture");
const P = require("./feature-2507-test-gates-node/parity-cases");
const L = require("./feature-2507-test-gates-node/placement-launch-cases");
const M = require("./feature-2507-test-gates-node/merge-3way-cases");

const restore = isolate();
after(() => {
  F.cleanup();
  M.cleanup();
  restore();
});

const runsOf = (cli) => F.RUNS.filter((r) => r.cli === cli);
const goldenOf = (id) => {
  const g = F.golden()[id];
  assert.ok(g, `golden holds run ${id}`);
  return g;
};

// matchGolden(cli, runner, label) — every run of the CLI against its golden record.
async function matchGolden(cli, runner, label) {
  const skipped = [];
  for (const run of runsOf(cli)) {
    if (label === "node" && run.path === "noNode") continue; // in-process: node is always there
    const got = await runner(run);
    if (got.skipped) {
      skipped.push(`${run.id}: ${got.skipped}`);
      continue;
    }
    const want = goldenOf(run.id);
    if (run.path === "noNode") {
      assert.strictEqual(got.rc, 2, `${run.id}: no node on PATH gives rc 2`);
      assert.ok(got.stderr.length > 0, `${run.id}: says why on stderr`);
      continue;
    }
    assert.deepStrictEqual({ rc: got.rc, stdout: got.stdout, stderr: got.stderr }, { rc: want.rc, stdout: want.stdout, stderr: want.stderr }, `${label} ${run.id}`);
  }
  if (skipped.length) console.log(`# host gap (${cli}/${label}): ${skipped.join("; ")}`);
}

// The golden is the pinned truth only if each run shows the codes it is there for.
function goldenCoverage(cli) {
  for (const run of runsOf(cli)) {
    const g = goldenOf(run.id);
    for (const code of run.codes) assert.ok(`${g.stdout}${g.stderr}`.includes(`code=${code}`) || `${g.stderr}`.includes(`${code}:`), `${run.id}: golden shows ${code}`);
  }
}

caseBegin("bash-frontmatter-golden", "bin/check-test-frontmatter.sh");
test("check-test-frontmatter.sh: corpus runs match the golden and show their codes", async () => {
  goldenCoverage("frontmatter");
  await matchGolden("frontmatter", F.bashRun, "bash");
});
caseEnd();

caseBegin("node-frontmatter-golden", "bin/check-test-frontmatter/cli.js");
test("check-test-frontmatter/cli.js run(): the same bytes and rc as the golden", () => matchGolden("frontmatter", F.nodeRun, "node"));
caseEnd();

caseBegin("bash-case-markers-golden", "bin/check-case-markers.sh");
test("check-case-markers.sh: corpus runs match the golden and show their codes", async () => {
  goldenCoverage("markers");
  await matchGolden("markers", F.bashRun, "bash");
});
caseEnd();

caseBegin("node-case-markers-golden", "bin/check-case-markers/cli.js");
test("check-case-markers/cli.js run(): the same bytes and rc as the golden", () => matchGolden("markers", F.nodeRun, "node"));
caseEnd();

caseBegin("bash-language-match-golden", "bin/check-test-language-match.sh");
test("check-test-language-match.sh: corpus runs match the golden and show their codes", async () => {
  goldenCoverage("langmatch");
  await matchGolden("langmatch", F.bashRun, "bash");
});
caseEnd();

caseBegin("node-language-match-golden", "bin/check-test-language-match/cli.js");
test("check-test-language-match/cli.js run(): the same bytes and rc as the golden", () => matchGolden("langmatch", F.nodeRun, "node"));
caseEnd();

caseBegin("bash-self-impl-golden", "bin/check-self-impl.sh");
test("check-self-impl.sh: corpus runs match the golden and show their codes", async () => {
  goldenCoverage("selfimpl");
  await matchGolden("selfimpl", F.bashRun, "bash");
});
caseEnd();

caseBegin("node-self-impl-golden", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): the same bytes and rc as the golden", () => matchGolden("selfimpl", F.nodeRun, "node"));
caseEnd();

caseBegin("node-case-markers-pester-reader-conforming", "bin/check-case-markers/cli.js");
test("check-case-markers/cli.js run(): a conforming pester file passes through the pwsh reader child, as bash", { skip: R.skipReason("pester") }, () => R.conforming("pester"));
caseEnd();

caseBegin("node-case-markers-pytest-reader-conforming", "bin/check-case-markers/cli.js");
test("check-case-markers/cli.js run(): a conforming pytest file passes through the uv reader child, as bash", { skip: R.skipReason("pytest") }, () => R.conforming("pytest"));
caseEnd();

caseBegin("placement-table-hook-js", "hooks/block-case-markers.js");
test("the placement table holds for block-case-markers.js", () => L.placementHookJs());
caseEnd();

caseBegin("placement-table-node", "hooks/lib/test-gates/placement.js");
test("placement.js answers the same placement table", () => L.placementNode());
caseEnd();

caseBegin("launch-lines-bash", "bin/lib/test-language-parts/pester.sh");
test("the bash pester / pytest parts still launch as the launch table says", () => L.launchLinesInBash());
caseEnd();

caseBegin("launch-spec-node", "hooks/lib/test-gates/parts/external-runtime.js");
test("external-runtime.js launchSpec(): the bash parts' arguments, helper for self-impl only", () => L.launchSpecNode());
caseEnd();

caseBegin("headers-parity", "hooks/lib/test-gates/headers.js");
test("headers.js reads the Tests: / Tags: lines as the retired extract_headers did", () => P.headers());
caseEnd();

caseBegin("case-records-parity", "hooks/lib/test-gates/case-records.js");
test("case-records.js prints the crr_read TSV for every corpus file", () => P.caseRecords());
caseEnd();

caseBegin("case-records-unavailable", "hooks/lib/test-gates/case-records.js");
test("case-records.js: no pwsh / uv on PATH gives FILE unavailable naming the runtime", () => P.recordsUnavailable());
caseEnd();

caseBegin("case-embed-deps-failed", "hooks/lib/test-gates/case-markers.js");
test("an unreachable caseEmbedRules part gives uncertain/case-embed and CASE_EMBED_DEPS_FAILED", () => P.depsFailed());
caseEnd();

caseBegin("self-impl-parity", "hooks/lib/test-gates/self-impl.js");
test("self-impl.js report() answers rc and rows as tsi_report", () => P.selfImplWindow());
caseEnd();

caseBegin("self-impl-unavailable", "hooks/lib/test-gates/self-impl.js");
test("self-impl.js: no pwsh / uv on PATH gives tsi_report's runtime rc", () => P.selfImplUnavailable());
caseEnd();

caseBegin("code-language-parity", "hooks/lib/test-gates/code-language.js");
test("code-language.js maps Tests: tokens as _trl_token_index (patterns, shebangs, none)", () => P.codeLanguage());
caseEnd();

caseBegin("bash-case-embed-parity", "hooks/lib/test-gates/parts/bash-case-embed.js");
test("parts/bash-case-embed.js: self-impl and case-count as bash_case_embed", () => P.bashEmbed());
caseEnd();

caseBegin("content-normalization", "hooks/lib/test-gates/frontmatter.js");
test("normalizeContent(): trailing LFs cut, one LF added, CRs kept", () => P.normalizeContent());
caseEnd();

caseBegin("self-impl-cli-two-heads-and-base-count-3-way", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): --head x2 --base counts H + M - B per key, clamped at 0", () => M.selfImplCli3Way());
caseEnd();

caseBegin("self-impl-cli-identical-heads-without-base", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): identical heads without a base judge against that one blob", () => M.selfImplCliTwoHeadsNoBase());
caseEnd();

caseBegin("self-impl-cli-equal-to-a-parent-is-skipped", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): a file equal to HEAD or to MERGE_HEAD is not judged", () => M.selfImplCliEqualToAParent());
caseEnd();

caseBegin("self-impl-cli-head-base-arg-errors", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): bad --head / --base combinations give rc 2", () => M.selfImplCliArgErrors());
caseEnd();

caseBegin("self-impl-cli-single-head-unchanged", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): the single --head and no-head forms keep their verdicts", () => M.selfImplCliSingleHeadUnchanged());
caseEnd();

caseBegin("self-impl-cli-5-column-manifest", "bin/check-self-impl/cli.js");
test("check-self-impl/cli.js run(): a 5-column manifest judges each row 3-way", () => M.selfImplCliManifest5());
caseEnd();

caseBegin("self-impl-judge-two-heads-and-base", "bin/check-self-impl/cli.js");
test("self-impl-judge judge(): heads + base answer the 3-way table", () => M.judge3Way());
caseEnd();

caseBegin("language-match-cli-head-base-and-declaration-only", "bin/check-test-language-match/cli.js");
test("check-test-language-match/cli.js run(): --head x2 --base and --declaration-only alone", () => M.langMatchArgs());
caseEnd();
