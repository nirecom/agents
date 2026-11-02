"use strict";
// Tests: bin/check-glossary-drift, bin/plan-artifact-path, bin/plan-link
// Tags: TL2, bin, glossary, plan-link, cli, migration, compat, deterministic, scope:issue-specific
// #2820: the three CLIs take --step <workflow step>; --stage stays a deprecated alias that maps
// the legacy value onto the same step (same stdout, a warning on stderr). Both flags, or a value
// outside the flag's own set, is a usage error (rc 2). The printed plan paths keep the plan
// artifact names (<sid>-intent.md and so on).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const F = require("./feat-2529-glossary-drift/fixture");
after(() => {
  F.finish();
  restore();
});
const verdict = (fn) => () => noNewFailures(F.failureCount, fn);

const DEPRECATED = /--stage is deprecated; use --step /;
// Legacy --stage value -> the workflow step it now names, per CLI.
const GLOSSARY = [["intent", "clarify_intent"], ["outline", "outline"], ["detail", "detail"],
  ["tests", "review_tests"], ["code", "review_security"], ["docs", "review_docs"]];
const PLAN = GLOSSARY.slice(0, 3);
const ARTIFACT = { clarify_intent: "intent", outline: "outline", detail: "detail" };

// One variant ("glossary-drift") in the artifact each step scans.
const VARIANT = "Mid-line the glossary-drift shows up here.";
function placeVariant(repo, sid, step) {
  const js = `"use strict";\n// ${VARIANT}\nmodule.exports = 1;\n`;
  if (step === "clarify_intent") F.writeIntent(sid, { goal: VARIANT });
  else if (step === "outline" || step === "detail") F.writePlan(sid, step, `# Plan\n\n## Approach\n\n${VARIANT}\n`);
  else if (step === "review_tests") F.stageFile(repo, "tests/t.js", js);
  else if (step === "review_security") F.stageFile(repo, "bin/a.js", js);
  else F.stageFile(repo, "docs/guide.md", `# Guide\n\n${VARIANT}\n`);
}

const drift = (args, cwd) => F.runNode("bin/check-glossary-drift", args, { cwd });
const describe = (r) => `code=${r.code} ${r.all}`;

function glossaryPerStep() {
  for (const [legacy, step] of GLOSSARY) {
    const repo = F.mkRepo(`cli-${step}`);
    const sid = F.newSid(`cli-${step}`);
    placeVariant(repo, sid, step);
    F.seedAt(sid, step, repo);
    const r = drift(["--session", sid, "--step", step], repo);
    F.check(`check-glossary-drift --step ${step}: exit 1 with a finding`, F.reached(r) && r.code === 1, describe(r));
    const lines = F.driftLines(r.out);
    F.check(`check-glossary-drift --step ${step}: DRIFT lines name the step`,
      lines.length > 0 && lines.every((d) => d.step === step), r.out);
    const accepts = r.out.split(/\r?\n/).filter((l) => l.includes("<<WORKFLOW_GLOSSARY_ACCEPTED"));
    F.check(`check-glossary-drift --step ${step}: accept line carries step=${step}`,
      accepts.length > 0 && accepts.every((l) => l.includes(` step=${step} — `) && !/\bstage=/.test(l)), r.out);
    F.check(`check-glossary-drift --step ${step}: no deprecation warning`, !DEPRECATED.test(r.err), r.err);

    const l = drift(["--session", sid, "--stage", legacy], repo);
    F.check(`check-glossary-drift --stage ${legacy}: same exit and stdout as --step ${step}`,
      F.reached(l) && l.code === r.code && l.out === r.out, `${describe(l)} || want ${describe(r)}`);
    F.check(`check-glossary-drift --stage ${legacy}: deprecation warning on stderr`, DEPRECATED.test(l.err), l.err);
  }
}

function glossaryUsage() {
  const repo = F.mkRepo("cli-usage");
  const sid = F.newSid("cli-usage");
  F.seedAt(sid, "outline", repo);
  const BAD = [
    ["both flags", ["--step", "outline", "--stage", "outline"]],
    ["both flags, --stage first", ["--stage", "outline", "--step", "outline"]],
    ["legacy value under --step (intent)", ["--step", "intent"]],
    ["legacy value under --step (tests)", ["--step", "tests"]],
    ["step outside the glossary steps (write_code)", ["--step", "write_code"]],
    ["unknown --step value", ["--step", "bogus"]],
    ["step name under --stage", ["--stage", "review_tests"]],
    ["unknown --stage value", ["--stage", "bogus"]],
  ];
  for (const [label, args] of BAD) {
    const r = drift(["--session", sid].concat(args), repo);
    F.check(`check-glossary-drift ${label}: exit 2`, F.reached(r) && r.code === 2, describe(r));
  }
  const r = drift(["--session", sid, "--step", "bogus"], repo);
  const m = /--step <([^>]*)>/.exec(r.err);
  const listed = m ? m[1].split("|").sort() : [];
  F.check("check-glossary-drift usage lists exactly the six glossary steps under --step",
    JSON.stringify(listed) === JSON.stringify(GLOSSARY.map(([, s]) => s).sort()), r.err);
}

// --stage <legacy> --record writes the same step-keyed glossary_check that --step --record writes.
function glossaryRecordAlias() {
  for (const [legacy, step] of [["tests", "review_tests"], ["intent", "clarify_intent"]]) {
    const repo = F.mkRepo(`cli-rec-${step}`);
    const sid = F.newSid(`cli-rec-${step}`);
    placeVariant(repo, sid, step);
    F.seedAt(sid, step, repo);
    const l = F.driftLegacy(sid, step, repo, true);
    F.check(`check-glossary-drift --stage ${legacy} --record: exit 1 with a finding, deprecation warning`,
      F.reached(l) && l.code === 1 && DEPRECATED.test(l.err), describe(l));
    const rec = F.recordOf(sid, step);
    F.check(`check-glossary-drift --stage ${legacy} --record: glossary_check under ${step} carries step=${step} and no stage`,
      !!rec && rec.step === step && !("stage" in rec) && Array.isArray(rec.findings) && rec.findings.length > 0, JSON.stringify(rec));
    const r = F.drift(sid, step, repo, true);
    const rec2 = F.recordOf(sid, step);
    F.check(`check-glossary-drift --step ${step} --record: same record as the --stage ${legacy} run`,
      F.reached(r) && r.code === 1 && !!rec && !!rec2 && rec2.step === step && rec2.fingerprint === rec.fingerprint &&
      JSON.stringify(rec2.findings) === JSON.stringify(rec.findings), JSON.stringify({ rec, rec2 }));
  }
}

const artifactPath = (args) => F.runNode("bin/plan-artifact-path", args, {});
function planArtifactPath() {
  const sid = F.newSid("pap");
  const base = ["--session", sid, "--plans-dir", F.PLANS_DIR];
  for (const [legacy, step] of PLAN) {
    const r = artifactPath(base.concat(["--step", step]));
    const want = `${sid}-${ARTIFACT[step]}.md`;
    F.check(`plan-artifact-path --step ${step}: exit 0, path keeps the artifact name ${want}`,
      F.reached(r) && r.code === 0 && F.slash(r.out.trim()).endsWith(`/${want}`), describe(r));
    F.check(`plan-artifact-path --step ${step}: no deprecation warning`, !DEPRECATED.test(r.err), r.err);
    const l = artifactPath(base.concat(["--stage", legacy]));
    F.check(`plan-artifact-path --stage ${legacy}: same exit and stdout as --step ${step}`,
      F.reached(l) && l.code === r.code && l.out === r.out, `${describe(l)} || want ${describe(r)}`);
    F.check(`plan-artifact-path --stage ${legacy}: deprecation warning on stderr`, DEPRECATED.test(l.err), l.err);
  }
  for (const [label, args] of [["both flags", ["--step", "outline", "--stage", "outline"]],
    ["artifact name under --step", ["--step", "intent"]], ["glossary step under --step", ["--step", "review_tests"]],
    ["unknown --step value", ["--step", "bogus"]], ["glossary-only legacy value under --stage", ["--stage", "tests"]],
    ["step name under --stage", ["--stage", "clarify_intent"]], ["no flag", []]]) {
    const r = artifactPath(base.concat(args));
    F.check(`plan-artifact-path ${label}: exit 2`, F.reached(r) && r.code === 2, describe(r));
  }
}

const planLink = (args) => F.runNode("bin/plan-link", args, { cwd: fs.mkdtempSync(path.join(os.tmpdir(), "f2820-pl-")) });
function planLinkCli() {
  const sid = require("node:crypto").randomUUID(); // plan-link accepts only a UUID or YYYYMMDD-HHMMSS session id
  for (const a of Object.values(ARTIFACT)) F.writePlan(sid, a, `# ${a}\n\nfixture\n`);
  const head = (out) => out.split(/\r?\n/).filter(Boolean).map((l) => l.split(":")[0]);
  for (const [legacy, step] of PLAN) {
    const a = ARTIFACT[step];
    const r = planLink(["--session", sid, "--step", step]);
    F.check(`plan-link --step ${step}: exit 0, one line for the ${a} artifact at ${sid}-${a}.md`,
      F.reached(r) && r.code === 0 && JSON.stringify(head(r.out)) === JSON.stringify([a]) && r.out.includes(`${sid}-${a}.md`), describe(r));
    F.check(`plan-link --step ${step}: no deprecation warning`, !DEPRECATED.test(r.err), r.err);
    const l = planLink(["--session", sid, "--stage", legacy]);
    F.check(`plan-link --stage ${legacy}: same exit and stdout as --step ${step}`,
      F.reached(l) && l.code === r.code && l.out === r.out, `${describe(l)} || want ${describe(r)}`);
    F.check(`plan-link --stage ${legacy}: deprecation warning on stderr`, DEPRECATED.test(l.err), l.err);
  }
  const all = planLink(["--session", sid]);
  F.check("plan-link without a flag: every plan artifact, one line each",
    F.reached(all) && all.code === 0 && JSON.stringify(head(all.out)) === JSON.stringify(["intent", "outline", "detail"]), describe(all));
  for (const [label, args] of [["both flags", ["--step", "detail", "--stage", "detail"]],
    ["artifact name under --step", ["--step", "intent"]], ["glossary step under --step", ["--step", "review_docs"]],
    ["unknown --step value", ["--step", "bogus"]], ["glossary-only legacy value under --stage", ["--stage", "docs"]],
    ["step name under --stage", ["--stage", "clarify_intent"]]]) {
    const r = planLink(["--session", sid].concat(args));
    F.check(`plan-link ${label}: exit 2`, F.reached(r) && r.code === 2, describe(r));
  }
}

caseBegin("check-glossary-drift --step per glossary step, --stage as the deprecated alias", "bin/check-glossary-drift");
test("check-glossary-drift --step per glossary step, --stage as the deprecated alias", verdict(glossaryPerStep));
caseEnd();

caseBegin("check-glossary-drift usage errors and the USAGE step list", "bin/check-glossary-drift");
test("check-glossary-drift usage errors and the USAGE step list", verdict(glossaryUsage));
caseEnd();

caseBegin("check-glossary-drift --stage legacy --record writes the step-keyed record", "bin/check-glossary-drift");
test("check-glossary-drift --stage legacy --record writes the step-keyed record", verdict(glossaryRecordAlias));
caseEnd();

caseBegin("plan-artifact-path --step, --stage alias, usage errors", "bin/plan-artifact-path");
test("plan-artifact-path --step, --stage alias, usage errors", verdict(planArtifactPath));
caseEnd();

caseBegin("plan-link --step, --stage alias, all artifacts by default, usage errors", "bin/plan-link");
test("plan-link --step, --stage alias, all artifacts by default, usage errors", verdict(planLinkCli));
caseEnd();
