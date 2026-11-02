"use strict";
// Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/lib/plan-confirm-flag.js, hooks/workflow-state/plan-step-table.js
// Tags: TL1, TL2, workflow, skip-authorization, confirm-flag, config-dependent, scope:issue-specific
// #2820: the skip doors key the CONFIRM_* flag by workflow step (CONFIRM_FLAG_OF_STEP), the flag
// reader takes the flag name (isConfirmFlagOffFromFile), and the plan step table lives in
// plan-step-table.js with the artifact-name set derived from its rows. Every probe runs in a child
// whose AGENTS_MAIN_ROOT points at a temp .env, so the developer's own config never decides.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const CE = require("../lib/confirm-env-fixture");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2820-flag-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const REPO = path.resolve(__dirname, "..", "..");
const PSA = path.join(REPO, "hooks/workflow-state/plan-skip-allowance.js");
const PCF = path.join(REPO, "hooks/lib/plan-confirm-flag.js");
const TABLE = path.join(REPO, "hooks/workflow-state/plan-step-table.js");
const ALL_CONFIRM = ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL", "CONFIRM_TESTS", "CONFIRM_CODE"];

// probe(fileVars, exported, expr) -> the JSON value of `expr` evaluated in a child with
// psa / pcf / table in scope. fileVars go to $AGENTS_MAIN_ROOT/.env; exported go to the env.
function probe(fileVars, exported, expr) {
  const env = CE.childEnvWith(CE.confirmEnvRoot(TMP, fileVars));
  for (const k of ALL_CONFIRM) delete env[k];
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDE_PROJECT_DIR;
  Object.assign(env, exported || {});
  const src = [
    "const t = (p) => { try { return require(p); } catch (e) { return { __missing: e.code || e.message }; } };",
    `const psa = t(${JSON.stringify(PSA)}); const pcf = t(${JSON.stringify(PCF)}); const table = t(${JSON.stringify(TABLE)});`,
    `let v; try { v = (${expr}); } catch (e) { v = "THREW:" + e.message; }`,
    "process.stdout.write(JSON.stringify(v === undefined ? \"__undefined__\" : v));",
  ].join("\n");
  const r = spawnSync(process.execPath, ["-e", src], { env, cwd: TMP, encoding: "utf8", timeout: 60000 });
  try { return JSON.parse(r.stdout); } catch (_) { return "unparsed:" + r.stdout + r.stderr; }
}

const ON = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", CONFIRM_TESTS: "on" };
const off = (k) => Object.assign({}, ON, { [k]: "off" });
const doors = (step) => `[psa.isConfirmOffForStepSentinel(${JSON.stringify(step)}), psa.isConfirmOffForStepCli(${JSON.stringify(step)})]`;

caseBegin("confirm-flag-of-step-map", "hooks/workflow-state/plan-skip-allowance.js");
test("CONFIRM_FLAG_OF_STEP maps exactly outline / detail / write_tests to their flags", () => {
  const got = probe(ON, {}, "psa.CONFIRM_FLAG_OF_STEP");
  assert.deepStrictEqual(got, { outline: "CONFIRM_OUTLINE", detail: "CONFIRM_DETAIL", write_tests: "CONFIRM_TESTS" });
});
test("FILE_ONLY_STEPS holds outline and detail, not write_tests", () => {
  const got = probe(ON, {}, "Array.from(psa.FILE_ONLY_STEPS || []).sort()");
  assert.deepStrictEqual(got, ["detail", "outline"]);
});
test("the stage-keyed exports are retired", () => {
  const got = probe(ON, {}, "['STAGE_FOR_STEP', 'PLAN_STAGES'].filter((k) => k in psa)");
  assert.deepStrictEqual(got, []);
});
caseEnd();

caseBegin("clarify-intent-never-waived", "hooks/workflow-state/plan-skip-allowance.js");
test("CONFIRM_INTENT=off in the config file does not open clarify_intent on either door", () => {
  assert.deepStrictEqual(probe(off("CONFIRM_INTENT"), {}, doors("clarify_intent")), [false, false]);
});
test("CONFIRM_INTENT=off exported does not open clarify_intent either", () => {
  assert.deepStrictEqual(probe(ON, { CONFIRM_INTENT: "off" }, doors("clarify_intent")), [false, false]);
});
caseEnd();

caseBegin("file-only-steps", "hooks/workflow-state/plan-skip-allowance.js");
for (const [step, flag] of [["outline", "CONFIRM_OUTLINE"], ["detail", "CONFIRM_DETAIL"]]) {
  test(`${step}: ${flag}=off in the config file opens both doors`, () => {
    assert.deepStrictEqual(probe(off(flag), {}, doors(step)), [true, true]);
  });
  test(`${step}: an exported ${flag}=off over a file that says on opens neither door`, () => {
    assert.deepStrictEqual(probe(ON, { [flag]: "off" }, doors(step)), [false, false]);
  });
  test(`${step}: an exported ${flag}=on cannot revoke the file's off`, () => {
    assert.deepStrictEqual(probe(off(flag), { [flag]: "on" }, doors(step)), [true, true]);
  });
}
caseEnd();

caseBegin("write-tests-sentinel-reads-env", "hooks/workflow-state/plan-skip-allowance.js");
test("write_tests: an exported CONFIRM_TESTS=off opens the sentinel door only", () => {
  assert.deepStrictEqual(probe(ON, { CONFIRM_TESTS: "off" }, doors("write_tests")), [true, false]);
});
test("write_tests: CONFIRM_TESTS=off in the config file opens the CLI door", () => {
  assert.deepStrictEqual(probe(off("CONFIRM_TESTS"), {}, "psa.isConfirmOffForStepCli('write_tests')"), true);
});
test("a step outside CONFIRM_FLAG_OF_STEP (run_tests) opens neither door, whatever the config", () => {
  const all = { CONFIRM_INTENT: "off", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "off", CONFIRM_TESTS: "off", CONFIRM_CODE: "off" };
  assert.deepStrictEqual(probe(all, all, doors("run_tests")), [false, false]);
});
caseEnd();

caseBegin("plan-confirm-flag-by-flag-name", "hooks/lib/plan-confirm-flag.js");
test("getConfirmFlagName names the plan artifacts only ('tests' -> null)", () => {
  const got = probe(ON, {}, "['intent', 'outline', 'detail', 'tests', 'clarify_intent'].map((a) => pcf.getConfirmFlagName(a))");
  assert.deepStrictEqual(got, ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL", null, null]);
});
test("isConfirmFlagOffFromFile reads the named flag from the config file and ignores the env", () => {
  const got = probe(off("CONFIRM_DETAIL"), { CONFIRM_OUTLINE: "off" },
    "['CONFIRM_DETAIL', 'CONFIRM_OUTLINE', 'CONFIRM_INTENT'].map((f) => pcf.isConfirmFlagOffFromFile(f))");
  assert.deepStrictEqual(got, [true, false, false]);
});
test("the stage-keyed reader is retired", () => {
  assert.strictEqual(probe(ON, {}, "'isConfirmOffForStageFromFile' in pcf"), false);
});
caseEnd();

caseBegin("plan-step-table", "hooks/workflow-state/plan-step-table.js");
test("plan-step-table exports PLAN_STEP_TABLE keyed by the 3 gated steps", () => {
  assert.deepStrictEqual(probe(ON, {}, "table.__missing || Object.keys(table.PLAN_STEP_TABLE)"), ["clarify_intent", "outline", "detail"]);
});
test("PLAN_ARTIFACT_NAMES is derived from the rows' suffix", () => {
  const got = probe(ON, {}, "table.__missing || [Array.from(table.PLAN_ARTIFACT_NAMES), Object.values(table.PLAN_STEP_TABLE).map((r) => r.suffix)]");
  assert.deepStrictEqual(got, [["intent", "outline", "detail"], ["intent", "outline", "detail"]]);
});
test("rowFor / stepForSuffix convert between step and artifact name", () => {
  const got = probe(ON, {}, "table.__missing || [table.rowFor('clarify_intent').suffix, table.stepForSuffix('intent'), table.rowFor('intent')]");
  assert.deepStrictEqual(got, ["intent", "clarify_intent", null]);
});
test("plan-stage-table.js is gone", () => {
  assert.strictEqual(fs.existsSync(path.join(REPO, "hooks/workflow-state/plan-stage-table.js")), false);
});
caseEnd();
