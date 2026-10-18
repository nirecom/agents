"use strict";
// Tests: hooks/lib/jev/two-stage/jev-input.js
// Tags: TL2, hooks, jev, two-stage, jev-input, budget, required-sections, registry, cjk, scope:issue-specific, plan-sections, fallback-chain, validate-registry
// #2701: the Jev input has its own body budget (MAX_JEV_INPUT_CHARS = 30000), decoupled from
// the request state cap (MAX_STATE_CHARS stays 16000). write-tests / write-code require only the
// issue body; detail, outline and intent are plan sections packed by priority, and one of them
// full or truncated suffices. Other stages still require intent and issue body in full.
// TL3 gap (what this test does NOT catch):
// - real plans written by a live session (sizes here are fixtures modeled on observed ones)
// - Jev's server-side acceptance of a 30000-char input
// Closest-to-action mitigation: tests/bin/feature-2460-jev-judge.sh drives the CLI query path.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.resolve(__dirname, "..", "..");
const JEV_INPUT_JS = path.join(REPO, "hooks", "lib", "jev", "two-stage", "jev-input.js");
const COMMON_JS = path.join(REPO, "bin", "workflow", "lib", "jev-request-common.js");
const { REGISTRY, validateRegistry } = require(path.join(REPO, "hooks", "lib", "jev", "registry.js"));
const SID = "27010000-0000-4000-8000-000000002701";

// Both workflow dirs pinned (and the session id removed) before any module under test loads.
const restore = isolate();
const STATE_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2701-state-"));
const savedAgentsState = process.env.AGENTS_STATE_DIR;
process.env.AGENTS_STATE_DIR = STATE_ROOT;
after(() => {
  if (savedAgentsState === undefined) delete process.env.AGENTS_STATE_DIR;
  else process.env.AGENTS_STATE_DIR = savedAgentsState;
  restore();
  try { fs.rmSync(STATE_ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});
const PLANS = process.env.WORKFLOW_PLANS_DIR;

// Loaded per test, so a missing module fails each case by name instead of the whole file.
const jevInput = () => require(JEV_INPUT_JS);
const common = () => require(COMMON_JS);

// About half CJK (one UTF-16 unit each) and half ASCII, exactly n units.
const UNIT = "\\u8a2d\\u8a08\\u306e\\u8981\\u70b9\\u3068\\u5909\\u66f4\\u7bc4\\u56f2\\u3092\\u8aac\\u660e\\u3059\\u308b\\u77ed\\u3044\\u6587\\u7ae0\\u3067\\u3059\\u3002 Notes on scope here.\n";
const text = (n) => UNIT.repeat(Math.ceil(n / UNIT.length) + 1).slice(0, n);
const SIZES = { intent: 3700, outline: 4600, "issue body": 2500, detail: 17000 };
const PLAN_STAGES = ["write-tests", "write-code"];
const PLAN_ORDER = ["detail", "outline", "intent"];

const put = (name, body) => fs.writeFileSync(path.join(PLANS, `${SID}-${name}`), body);
const clearPlans = () => { for (const n of fs.readdirSync(PLANS)) fs.rmSync(path.join(PLANS, n), { recursive: true, force: true }); };

// writeFixture(sizes): the stage artifacts at the given sizes (a missing key = no file); a
// string value is written as that artifact's text instead of a sized filler.
function writeFixture(sizes, writeCode = "bin/report\n") {
  clearPlans();
  const body = (k) => (typeof sizes[k] === "string" ? sizes[k] : text(sizes[k]));
  if (sizes.intent !== undefined) put("intent.md", body("intent"));
  if (sizes.outline !== undefined) put("outline.md", body("outline"));
  if (sizes.detail !== undefined) put("detail.md", body("detail"));
  if (sizes["issue body"] !== undefined) {
    put("context.md", `# Context\n\n## Issue body\n\n${body("issue body")}\n\n## Issue metadata\n\n- number: 2701\n`);
  }
  if (writeCode !== null) put("write-code-files.txt", writeCode);
}

let seq = 0;
const tid = () => (0x2701000000000000n + BigInt(++seq)).toString(16).padStart(16, "0");
const CJ = REGISTRY["complexity-judge"];
const requiredOf = (stage) => CJ.required_sections_by_stage[stage];
const planOf = (stage) => (CJ.plan_sections_by_stage || {})[stage];
// build(stage, required): the module's result plus usedTid; the stage's plan sections (if any)
// go in as opts.planSections, the way query.js passes the registry's plan_sections_by_stage.
const build = (stage, required = requiredOf(stage)) => {
  const usedTid = tid();
  const opts = { repoRoot: null };
  if (planOf(stage)) opts.planSections = planOf(stage);
  return { ...jevInput().buildJevInput(SID, stage, usedTid, required, opts), usedTid };
};
const status = (r, required, plan) => common().requiredSectionsStatus(SID, required, r.sections, r.sources_failed, plan);

const PAIRS = [];
for (const [point, entry] of Object.entries(REGISTRY)) {
  for (const stage of entry.stages) PAIRS.push([point, stage, entry.required_sections_by_stage[stage]]);
}
const fixtureFor = (stage) => (PLAN_STAGES.includes(stage) ? SIZES
  : { intent: SIZES.intent, outline: SIZES.outline, "issue body": SIZES["issue body"] });

caseBegin("budget-decoupled", "hooks/lib/jev/two-stage/jev-input.js");
test("MAX_JEV_INPUT_CHARS is 30000 and MAX_STATE_CHARS stays 16000", () => {
  assert.strictEqual(jevInput().MAX_JEV_INPUT_CHARS, 30000);
  assert.strictEqual(common().MAX_STATE_CHARS, 16000);
});
caseEnd();

caseBegin("fit-every-point-stage", "hooks/lib/jev/two-stage/jev-input.js");
test("premise: the registry lists 8 point/stage pairs", () => {
  assert.strictEqual(PAIRS.length, 8, PAIRS.map((p) => `${p[0]}/${p[1]}`).join(","));
});
for (const [point, stage, required] of PAIRS) {
  test(`fit-${point}-${stage}: every required (and plan) section full, input within the budget`, () => {
    writeFixture(fixtureFor(stage));
    const r = build(stage, required);
    const plan = point === "complexity-judge" ? planOf(stage) : undefined;
    for (const s of required.concat(plan || [])) assert.strictEqual(r.sections[s], "full", `${s} (sections: ${JSON.stringify(r.sections)})`);
    assert.ok(r.text.length <= jevInput().MAX_JEV_INPUT_CHARS, `length ${r.text.length}`);
    assert.strictEqual(path.basename(r.file), `${SID}-jev-${r.usedTid}-input.md`, `file: ${r.file}`);
    assert.strictEqual(fs.readFileSync(r.file, "utf8"), r.text, "the file holds exactly the text");
    assert.strictEqual(status(r, required, plan).met, true);
  });
}
caseEnd();

caseBegin("optional-cut-keeps-required", "hooks/lib/jev/two-stage/jev-input.js");
test("complexity: an outline of the whole budget is cut, intent and issue body stay full", () => {
  const B = jevInput().MAX_JEV_INPUT_CHARS;
  const required = requiredOf("complexity");
  writeFixture({ intent: SIZES.intent, outline: B, "issue body": SIZES["issue body"] });
  const r = build("complexity", required);
  assert.ok(["truncated", "absent"].includes(r.sections.outline), `outline: ${r.sections.outline}`);
  assert.strictEqual(r.sections.intent, "full");
  assert.strictEqual(r.sections["issue body"], "full");
  assert.ok(r.text.length <= B, `length ${r.text.length}`);
  assert.strictEqual(status(r, required).met, true);
});
// The header is sized with the widest state word before the states are known, so an all-full
// input can end short of the budget by at most (header sections) x ("truncated" - "full").
// The header lists every stage source section, required or not.
const WC_ALL = () => common().STAGE_SOURCE_SECTIONS["write-code"];
const headerSlack = () => WC_ALL().length * ("truncated".length - "full".length);
const growDetail = (g) => {
  writeFixture(Object.assign({}, SIZES, { detail: SIZES.detail + g }));
  return build("write-code");
};
const allFull = (r) => WC_ALL().every((s) => r.sections[s] === "full") && r.text.length <= jevInput().MAX_JEV_INPUT_CHARS;
// wcEdge(): the largest detail growth g* at which every write-code section stays full (binary search).
let edgeMemo = null;
function wcEdge() {
  if (edgeMemo) return edgeMemo;
  const B = jevInput().MAX_JEV_INPUT_CHARS;
  assert.ok(allFull(growDetail(0)), "premise: the realistic fixture fits whole");
  assert.ok(!allFull(growDetail(B)), "premise: a detail grown by the whole budget does not");
  let lo = 0;
  let hi = B;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (allFull(growDetail(mid))) lo = mid; else hi = mid;
  }
  edgeMemo = { g: lo, at: growDetail(lo), past: growDetail(lo + 1) };
  return edgeMemo;
}
test("write-code: at the largest detail that keeps every section full, the input ends within the header slack of the budget", () => {
  const B = jevInput().MAX_JEV_INPUT_CHARS;
  const { g, at } = wcEdge();
  assert.ok(B - at.text.length <= headerSlack(), `gap ${B - at.text.length} > slack ${headerSlack()} at g*=${g}: the budget used is not B`);
  assert.strictEqual(status(at, requiredOf("write-code"), planOf("write-code")).met, true);
});
test("write-code: one char past that edge cuts only the lowest-priority intent", () => {
  const B = jevInput().MAX_JEV_INPUT_CHARS;
  const { g, past } = wcEdge();
  assert.ok(["truncated", "absent"].includes(past.sections.intent), `intent at g*+1=${g + 1}: ${past.sections.intent}`);
  for (const s of ["issue body", "write-code files", "detail", "outline"]) {
    assert.strictEqual(past.sections[s], "full", `${s} (sections: ${JSON.stringify(past.sections)})`);
  }
  assert.ok(past.text.length <= B, `length ${past.text.length}`);
  assert.strictEqual(status(past, requiredOf("write-code"), planOf("write-code")).met, true);
});
caseEnd();

caseBegin("fixture-exceeds-old-cap", "hooks/lib/jev/two-stage/jev-input.js");
test("the old write-code composition (intent + outline + detail + issue body) of the fixture exceeds the old 16000 cap", () => {
  const OLD_REQUIRED = ["intent", "outline", "detail", "issue body"];
  const total = OLD_REQUIRED.reduce((n, s) => n + `## ${s}\n`.length + SIZES[s] + 2, 0);
  assert.ok(total > common().MAX_STATE_CHARS, `old required total ${total}`);
  assert.ok(total <= jevInput().MAX_JEV_INPUT_CHARS, `old required total ${total} fits the new budget`);
});
caseEnd();

caseBegin("over-budget-insufficient", "hooks/lib/jev/two-stage/jev-input.js");
test("a required intent of the whole budget: requirement unmet, input still within the budget", () => {
  const B = jevInput().MAX_JEV_INPUT_CHARS;
  const required = requiredOf("complexity");
  writeFixture({ intent: B, "issue body": SIZES["issue body"] });
  const r = build("complexity", required);
  assert.notStrictEqual(r.sections.intent, "full");
  const st = status(r, required);
  assert.strictEqual(st.met, false);
  assert.ok(st.missing.includes("intent"), `missing: ${st.missing}`);
  assert.ok(r.text.length <= B, `length ${r.text.length}`);
});
caseEnd();

// A detail whose Steps block is the bulk, between a Files and a Risks section.
const MARK = { files: "FILES-MARK-2701", risks: "RISKS-MARK-2701", stepsEnd: "STEPS-END-2701" };
const bigDetail = (stepsHeading, n) => [
  "# Detail", "", "## Files to modify", "", `${MARK.files}: bin/report, tests/bin/report.sh`, "",
  stepsHeading, "", "### 1. first step", "", text(n), MARK.stepsEnd, "",
  "## Risks & edge cases", "", `${MARK.risks}: the flag collides with --quiet`, "",
].join("\n");

caseBegin("plan-sections-fallback-chain", "hooks/lib/jev/two-stage/jev-input.js");
for (const stage of PLAN_STAGES) {
  test(`${stage}: shipped registry requires the issue body only, plan sections detail > outline > intent`, () => {
    assert.deepStrictEqual(requiredOf(stage), ["issue body"]);
    assert.deepStrictEqual(planOf(stage), PLAN_ORDER);
  });
  test(`${stage}: detail fits whole -> all full, order issue body, (write-code files,) detail, outline, intent`, () => {
    writeFixture(SIZES);
    const r = build(stage);
    for (const s of ["issue body"].concat(PLAN_ORDER)) assert.strictEqual(r.sections[s], "full", `${s}: ${JSON.stringify(r.sections)}`);
    const order = ["issue body"].concat(stage === "write-code" ? ["write-code files"] : [], PLAN_ORDER);
    const at = order.map((s) => r.text.indexOf(`\n## ${s}\n`));
    assert.ok(at.every((i, k) => i >= 0 && (k === 0 || i > at[k - 1])), `section offsets ${order.join(",")}: ${at.join(",")}`);
    assert.deepStrictEqual(status(r, requiredOf(stage), planOf(stage)), { met: true, missing: [], exempt: [] });
  });
  for (const heading of ["## Steps", "## \\u5b9f\\u88c5\\u30b9\\u30c6\\u30c3\\u30d7"]) {
    test(`${stage}: detail over the budget (${heading}) -> outline whole, detail truncated with Steps moved last, Files and Risks kept`, () => {
      const B = jevInput().MAX_JEV_INPUT_CHARS;
      writeFixture({ intent: SIZES.intent, outline: SIZES.outline, "issue body": SIZES["issue body"], detail: bigDetail(heading, B) });
      const r = build(stage);
      assert.strictEqual(r.sections.outline, "full", JSON.stringify(r.sections));
      assert.strictEqual(r.sections.detail, "truncated", JSON.stringify(r.sections));
      assert.strictEqual(r.sections["issue body"], "full");
      assert.ok(r.text.includes(MARK.files), "the Files to modify section survives");
      assert.ok(r.text.includes(MARK.risks), "the Risks section after Steps survives (Steps moved last)");
      assert.ok(!r.text.includes(MARK.stepsEnd), "the Steps block is the part cut");
      const steps = r.text.indexOf(`\n${heading}\n`);
      assert.ok(steps < 0 || steps > r.text.indexOf(MARK.risks), "Steps heading follows the Risks section");
      assert.ok(r.text.length <= B, `length ${r.text.length}`);
      assert.deepStrictEqual(status(r, requiredOf(stage), planOf(stage)), { met: true, missing: [], exempt: [] });
    });
  }
  test(`${stage}: outline over half the room -> outline truncated, detail truncated, still sufficient`, () => {
    const B = jevInput().MAX_JEV_INPUT_CHARS;
    writeFixture({ intent: SIZES.intent, outline: B, "issue body": SIZES["issue body"], detail: bigDetail("## Steps", B) });
    const r = build(stage);
    assert.strictEqual(r.sections.outline, "truncated", JSON.stringify(r.sections));
    assert.strictEqual(r.sections.detail, "truncated", JSON.stringify(r.sections));
    assert.strictEqual(r.sections["issue body"], "full");
    assert.ok(r.text.length <= B, `length ${r.text.length}`);
    assert.strictEqual(status(r, requiredOf(stage), planOf(stage)).met, true);
  });
  test(`${stage}: only intent present -> sufficient`, () => {
    writeFixture({ intent: SIZES.intent, "issue body": SIZES["issue body"] });
    const r = build(stage);
    assert.strictEqual(r.sections.intent, "full");
    assert.strictEqual(r.sections.detail, "absent");
    assert.strictEqual(r.sections.outline, "absent");
    assert.deepStrictEqual(status(r, requiredOf(stage), planOf(stage)), { met: true, missing: [], exempt: [] });
  });
  test(`${stage}: detail, outline and intent all absent -> insufficient, missing names all three`, () => {
    writeFixture({ "issue body": SIZES["issue body"] });
    const r = build(stage);
    const st = status(r, requiredOf(stage), planOf(stage));
    assert.strictEqual(st.met, false);
    assert.deepStrictEqual(st.missing, PLAN_ORDER);
  });
  test(`${stage}: issue body absent -> insufficient on the issue body alone`, () => {
    writeFixture({ intent: SIZES.intent, outline: SIZES.outline, detail: SIZES.detail });
    const st = status(build(stage), requiredOf(stage), planOf(stage));
    assert.strictEqual(st.met, false);
    assert.deepStrictEqual(st.missing, ["issue body"]);
  });
  test(`${stage}: issue body over the budget -> insufficient, input within the budget`, () => {
    const B = jevInput().MAX_JEV_INPUT_CHARS;
    writeFixture({ intent: SIZES.intent, outline: SIZES.outline, detail: SIZES.detail, "issue body": B });
    const r = build(stage);
    assert.notStrictEqual(r.sections["issue body"], "full");
    const st = status(r, requiredOf(stage), planOf(stage));
    assert.strictEqual(st.met, false);
    assert.ok(st.missing.includes("issue body"), `missing: ${st.missing}`);
    assert.ok(r.text.length <= B, `length ${r.text.length}`);
  });
}
caseEnd();

// verdict(edit): validateRegistry of a deep copy of complexity-judge after edit(copy).
const verdict = (edit) => {
  const e = JSON.parse(JSON.stringify(CJ));
  edit(e);
  return validateRegistry(e).length === 0 ? "accept" : "reject";
};
caseBegin("registry-plan-sections", "hooks/lib/jev/registry.js");
test("the shipped entries validate; only complexity-judge carries plan_sections_by_stage", () => {
  for (const p of Object.keys(REGISTRY)) assert.deepStrictEqual(validateRegistry(REGISTRY[p]), [], p);
  assert.ok(!("plan_sections_by_stage" in REGISTRY["outline-skip"]) && !("plan_sections_by_stage" in REGISTRY["detail-skip"]));
});
test("stages without plan sections still require intent and issue body", () => {
  for (const [point, stage, required] of PAIRS.filter((p) => !PLAN_STAGES.includes(p[1]))) {
    assert.ok(required.includes("intent") && required.includes("issue body"), `${point}/${stage}: ${required}`);
  }
});
test("accepted: a narrower plan list inside STAGE_SOURCE_SECTIONS", () => {
  assert.strictEqual(verdict((e) => { e.plan_sections_by_stage["write-code"] = ["outline", "intent"]; }), "accept");
});
test("rejected: a plan section outside STAGE_SOURCE_SECTIONS", () => {
  assert.strictEqual(verdict((e) => { e.plan_sections_by_stage["write-tests"] = ["detail", "write-code files"]; }), "reject");
  assert.strictEqual(verdict((e) => { e.plan_sections_by_stage["write-code"] = ["detail", "rm -rf /"]; }), "reject");
});
test("rejected: a plan section that is also required", () => {
  assert.strictEqual(verdict((e) => { e.plan_sections_by_stage["write-code"] = ["detail", "outline", "intent", "issue body"]; }), "reject");
  assert.strictEqual(verdict((e) => { e.required_sections_by_stage["write-tests"] = ["intent", "issue body"]; }), "reject");
});
test("rejected: without plan_sections_by_stage the intent is required again", () => {
  assert.strictEqual(verdict((e) => { delete e.plan_sections_by_stage; }), "reject");
  assert.strictEqual(verdict((e) => { delete e.plan_sections_by_stage["write-code"]; }), "reject");
});
test("rejected: the issue body stays required even with plan sections", () => {
  assert.strictEqual(verdict((e) => { e.required_sections_by_stage["write-code"] = ["detail"]; e.plan_sections_by_stage["write-code"] = ["outline", "intent"]; }), "reject");
});
caseEnd();

caseBegin("required-status-plan-arg", "bin/workflow/lib/jev-request-common.js");
const REQ = ["issue body"];
const st5 = (sections, failed, plan) => {
  clearPlans();
  return common().requiredSectionsStatus(SID, REQ, Object.assign({ "issue body": "full" }, sections), failed, plan);
};
test("a truncated plan section counts", () => {
  assert.deepStrictEqual(st5({ detail: "truncated", outline: "absent", intent: "absent" }, [], PLAN_ORDER), { met: true, missing: [], exempt: [] });
});
test("no plan section present: missing lists the plan sections in order", () => {
  assert.deepStrictEqual(st5({ detail: "absent", outline: "absent", intent: "absent" }, [], PLAN_ORDER), { met: false, missing: PLAN_ORDER, exempt: [] });
});
test("a plan section whose copy failed does not count", () => {
  assert.deepStrictEqual(st5({ detail: "full", outline: "absent", intent: "absent" }, ["detail"], PLAN_ORDER), { met: false, missing: PLAN_ORDER, exempt: [] });
  assert.strictEqual(st5({ detail: "full", outline: "full", intent: "absent" }, ["detail"], PLAN_ORDER).met, true);
});
test("required and plan sections both missing: both reported", () => {
  const st = st5({ "issue body": "absent", detail: "absent", outline: "absent", intent: "absent" }, [], PLAN_ORDER);
  assert.strictEqual(st.met, false);
  assert.deepStrictEqual(st.missing.slice().sort(), ["detail", "intent", "issue body", "outline"]);
});
test("a non-array or empty planSections is ignored (same as the 4-argument call)", () => {
  const absentPlan = { detail: "absent", outline: "absent", intent: "absent" };
  const four = st5(absentPlan, [], undefined);
  assert.deepStrictEqual(four, { met: true, missing: [], exempt: [] });
  for (const plan of ["detail", { 0: "detail" }, null, 7, []]) assert.deepStrictEqual(st5(absentPlan, [], plan), four, JSON.stringify(plan));
});
caseEnd();
