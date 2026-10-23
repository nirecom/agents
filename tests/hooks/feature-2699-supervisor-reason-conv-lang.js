"use strict";
// Tests: hooks/lib/conv-lang.js, hooks/lib/supervisor-reason-registry.js, hooks/supervisor-guard/audit-arm.js, hooks/stop-premature-stop-guard.js, hooks/supervisor-guard/format-integrated.js, hooks/lib/supervisor-report-format.js, hooks/lib/supervisor-findings-render.js, hooks/supervisor-trigger.js, hooks/workflow-gate/user-verified-audit.js, agents/supervisor.md, agents/supervisor-audit.md
// Tags: TL1, TL2, hooks, supervisor, conv-lang, static-sweep, agents, scope:issue-specific
// #2699: every supervisor reason/context shown to the user carries the CONV_LANG injection.
// (1) each "[EM Supervisor]"/"[C4 " literal sits in a registered generator or an injected formatter;
// (2) every registry entry injects under japanese and not under english; (3) the integrated and
// the bundled reason carry the injection exactly once; the two agent files follow CONV_LANG.
// TL3 gap (what this test does NOT catch):
// - the main conversation actually answering in the injected language
// Closest-to-action mitigation: (3) runs the real supervisor-guard on a Stop stdin payload.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const { after, test } = require("node:test");
const { scanSource, sweepFiles } = require("./feature-2699-supervisor-reason-conv-lang/scan");
const X = require("./feature-2698-supervisor/fixture");
const S = require("./feature-2698-supervisor/audit-scene");
const SMC = require("../lib/system-message-contract");

const restore = isolate();
const ROOT = X.tmpRoot("convlang");
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(ROOT, "transcripts-empty");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR, { recursive: true });
process.env.CONV_LANG = "english";
after(() => { restore(); X.rmRoot(ROOT); });

const REPO = path.resolve(__dirname, "..", "..");
const HOOKS = path.join(REPO, "hooks");
const REGISTRY = path.join(HOOKS, "lib", "supervisor-reason-registry.js");
const JA = "Respond to the user in japanese";
const count = (s, sub) => String(s).split(sub).length - 1;
const rel = (p) => path.relative(REPO, p).replace(/\\/g, "/");
const withLang = (lang, fn) => {
  const prev = process.env.CONV_LANG;
  process.env.CONV_LANG = lang;
  try { return fn(); } finally { process.env.CONV_LANG = prev; }
};

// The formatters that already inject (sweep baseline) and the one named exception: the launch
// section bundled into an alert block takes the alert reason's injection (plan 4-2 #1 / #9).
const INJECTED = {
  "hooks/lib/supervisor-report-format.js": ["formatCumSevErrorReason", "formatL2ArmedReason",
    "formatWorktreeOffProposalReason", "formatPreMergeBlockReason", "formatFreshnessBackstopReason"],
  "hooks/supervisor-guard/audit-arm.js": ["formatAuditLaunchSection"],
};
const INJECTED_FILES = new Set(["hooks/supervisor-off-proposal-shim.js"]);

function loadRegistry() {
  if (!fs.existsSync(REGISTRY)) return { missing: true, entries: [] };
  const m = require(REGISTRY);
  const entries = Array.isArray(m) ? m : (m.REGISTRY || m.registry || m.entries || []);
  return { missing: false, entries };
}
function resolveModule(mod) {
  for (const base of [path.dirname(REGISTRY), HOOKS, REPO]) {
    const p = path.isAbsolute(mod) ? mod : path.resolve(base, mod);
    for (const c of [p, p + ".js"]) if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  }
  return null;
}
const registered = () => loadRegistry().entries.map((e) => ({ ...e, file: e && e.module ? resolveModule(e.module) : null }));
// #2731 exemption: a `systemMessage:` property value whose text after the tag is one bare enum token
// plus key=value facts only (prose is never wrapped by withConvLang, so it must not appear there).
const FACT_TAIL = /^\s*(?:[a-z][\w-]*\s+)?(?:[A-Za-z][\w-]*=\S*\s*)+$/;
function isSystemMessageFact(l) {
  if (typeof l.srcLine !== "string") return false;
  const at = l.srcLine.indexOf(l.text.slice(0, 16));
  const tag = /^\[[^\]]+\]/.exec(l.text);
  return at > 0 && /systemMessage\s*:\s*[`"']$/.test(l.srcLine.slice(0, at)) && !!tag
    && FACT_TAIL.test(l.text.slice(tag[0].length)) && SMC.systemMessageProblems(l.text).length === 0;
}
// violations(literals, reg) -> "file:line in fn" for every literal outside an injected file, an
// injected formatter, a registry entry of the same file and export, or a systemMessage fact line.
function violations(literals, reg) {
  const allowed = (l) => INJECTED_FILES.has(l.file) || isSystemMessageFact(l)
    || (INJECTED[l.file] || []).includes(l.fn)
    || reg.some((e) => e.file && rel(e.file) === l.file && e.export === l.fn);
  return literals.filter((l) => !allowed(l)).map((l) => `${l.file}:${l.line} in ${l.fn || "<module scope>"}`);
}

caseBegin("scan-source-table", "tests/hooks/feature-2699-supervisor-reason-conv-lang/scan.js");
const BT = "`";
const SCAN_CASES = [
  { name: "a marker inside comments is not a literal",
    src: '// "[EM Supervisor] in a line comment"\n/* "[C4 premature-stop] in a block comment" */\nfunction f() { return 1; }', want: [] },
  { name: "nested template literal: one hit, attributed to the enclosing function",
    src: `function f(x) { return ${BT}[EM Supervisor] \${${BT}inner \${x}${BT}} done${BT}; }`, want: [{ line: 1, fn: "f" }] },
  { name: "anonymous function callback inside a named function -> the named one",
    src: 'function g() { return list.map(function () { return "[C4 premature-stop] x"; }); }', want: [{ line: 1, fn: "g" }] },
  { name: "arrow callback inside a named function -> the named one",
    src: 'function g2() {\n  arr.forEach((x) => { out.push("[EM Supervisor] y"); });\n}', want: [{ line: 2, fn: "g2" }] },
  { name: "anonymous callback at module scope -> null",
    src: 'setTimeout(() => { log("[EM Supervisor] z"); });', want: [{ line: 1, fn: null }] },
  { name: "split marker string on one line is detected as the concatenation",
    src: 'function h() { return "[EM " + "Supervisor] x"; }', want: [{ line: 1, fn: "h", text: "[EM Supervisor] x" }] },
  { name: "split marker string across lines, mixed quotes, reports the first piece's line",
    src: "function h2() {\n  return \"[C\" +\n    '4 premature-stop] y';\n}", want: [{ line: 2, fn: "h2", text: "[C4 premature-stop] y" }] },
  { name: "a split non-marker stays undetected",
    src: 'function q() { return "[EM" + "x]"; }', want: [] },
  { name: "braces inside a string and a regex do not move the frames",
    src: 'function k() { const r = /[{]/; const s = "}"; }\nconst m = "[C4 module]";', want: [{ line: 2, fn: null }] },
  { name: "method shorthand in an object literal",
    src: `const o = { build(a) { return ${BT}[C4 \${a}]${BT}; } };`, want: [{ line: 1, fn: "build" }] },
];
for (const c of SCAN_CASES) {
  test(`scanSource: ${c.name}`, () => {
    const got = scanSource(c.src).map((h) => ("text" in (c.want[0] || {}) ? { line: h.line, fn: h.fn, text: h.text } : { line: h.line, fn: h.fn }));
    assert.deepStrictEqual(got, c.want);
  });
}
test("an unregistered reason generator cannot slip through the sweep check", () => {
  const src = 'function rogueReason() { return "[EM Supervisor] " + "new reason"; }\nconst top = "[C4 top]";\n'
    + 'function formatCumSevErrorReason() { return "[EM Supervisor] same name, other file"; }';
  const lits = scanSource(src).map((l) => ({ file: "hooks/lib/supervisor-rogue.js", ...l }));
  assert.deepStrictEqual(violations(lits, []), ["hooks/lib/supervisor-rogue.js:1 in rogueReason",
    "hooks/lib/supervisor-rogue.js:2 in <module scope>", "hooks/lib/supervisor-rogue.js:3 in formatCumSevErrorReason"]);
  const reg = [{ file: path.join(REPO, "hooks/lib/supervisor-rogue.js"), export: "rogueReason" }];
  assert.deepStrictEqual(violations(lits, reg).length, 2, "registering rogueReason clears only that literal");
  const injected = [{ file: "hooks/lib/supervisor-report-format.js", line: 1, fn: "formatCumSevErrorReason" },
    { file: "hooks/supervisor-off-proposal-shim.js", line: 1, fn: null }];
  assert.deepStrictEqual(violations(injected, []), [], "an injected formatter and an injected file pass");
});
test("only a systemMessage fact line is exempt; prose or a non-systemMessage literal is still flagged", () => {
  const src = [
    "function a(f) { out({ systemMessage: `[EM Supervisor] block severity=error findings=${f.length}` }); }",
    'function b() { out({ systemMessage: "[EM Supervisor] please review the findings now" }); }',
    'function c() { out({ systemMessage: "[EM Supervisor] please review" }); }',
    'function d() { out({ reason: "[EM Supervisor] block severity=error" }); }',
    'function e() { out({ systemMessage: "[C4 premature-stop] stop blocked for this turn count=2" }); }',
  ].join("\n");
  const lines = src.split("\n");
  const lits = scanSource(src).map((l) => ({ file: "hooks/lib/supervisor-rogue.js", srcLine: lines[l.line - 1], ...l }));
  assert.deepStrictEqual(violations(lits, []), ["hooks/lib/supervisor-rogue.js:2 in b",
    "hooks/lib/supervisor-rogue.js:3 in c", "hooks/lib/supervisor-rogue.js:4 in d", "hooks/lib/supervisor-rogue.js:5 in e"]);
});
caseEnd();

caseBegin("with-conv-lang-helper", "hooks/lib/conv-lang.js");
test("withConvLang prefixes the injection + newline under japanese and returns text unchanged under english", () => {
  const { withConvLang, getConvLangInjection } = require("../../hooks/lib/conv-lang");
  assert.strictEqual(typeof withConvLang, "function", "conv-lang.js exports withConvLang");
  withLang("japanese", () => assert.strictEqual(withConvLang("body"), `${getConvLangInjection()}\nbody`));
  withLang("english", () => assert.strictEqual(withConvLang("body"), "body"));
});
caseEnd();

caseBegin("static-sweep-literals-registered", "hooks/lib/supervisor-reason-registry.js");
test("every [EM Supervisor]/[C4 literal in the supervisor file set is in a registered or injected generator", () => {
  const files = sweepFiles(HOOKS);
  const literals = [];
  for (const f of files) {
    const src = fs.readFileSync(f, "utf8");
    const lines = src.split(/\r?\n/);
    for (const l of scanSource(src)) literals.push({ file: rel(f), srcLine: lines[l.line - 1], ...l });
  }
  assert.ok(literals.length >= 20, `the scanner sees the known literals (${literals.length})`);
  assert.ok(literals.some((l) => l.file === "hooks/lib/supervisor-report-format.js" && l.fn === "formatCumSevErrorReason"),
    "scanner sanity: formatCumSevErrorReason's literal is attributed to it");
  assert.deepStrictEqual(violations(literals, registered()), [], "unregistered reason generators");
});
caseEnd();

caseBegin("registry-covers-plan-generators", "hooks/lib/supervisor-reason-registry.js");
test("the registry lists the plan 4-2 #1-#8 generators with callable exports", () => {
  const { missing } = loadRegistry();
  assert.ok(!missing, "hooks/lib/supervisor-reason-registry.js exists");
  const reg = registered();
  const has = (file, exp) => reg.some((e) => e.file && rel(e.file) === file && e.export === exp);
  for (const [file, exp] of [
    ["hooks/supervisor-guard/audit-arm.js", "formatAuditArmReason"],
    ["hooks/stop-premature-stop-guard.js", "formatPrematureStopReason"],
    ["hooks/stop-premature-stop-guard.js", "formatMechanismFailureReason"],
    ["hooks/supervisor-guard/format-integrated.js", "formatIntegratedReason"],
    ["hooks/lib/supervisor-report-format.js", "formatL3StageBoundaryReason"],
    ["hooks/lib/supervisor-report-format.js", "formatL3SeverityThresholdReason"],
    ["hooks/lib/supervisor-findings-render.js", "formatLayer2Findings"],
    ["hooks/workflow-gate/user-verified-audit.js", "holdReason"],
    ["hooks/workflow-gate/user-verified-audit.js", "armReason"],
  ]) assert.ok(has(file, exp), `registered: ${file} ${exp}`);
  assert.ok(reg.some((e) => e.file && rel(e.file) === "hooks/supervisor-trigger.js"), "the supervisor-trigger advisory is registered (#7)");
  assert.ok(reg.filter((e) => e.file && rel(e.file) === "hooks/workflow-gate/user-verified-audit.js").length >= 4,
    "user-verified-audit registers holdReason, armReason and the two extracted inline reasons (#8)");
  for (const e of reg) {
    assert.ok(e.file, `module resolves: ${e.module}`);
    assert.strictEqual(typeof require(e.file)[e.export], "function", `${e.module} exports ${e.export}`);
    assert.ok(Array.isArray(e.sampleArgs), `${e.export} has sampleArgs`);
  }
});
caseEnd();

caseBegin("registry-entries-inject-per-lang", "hooks/lib/supervisor-reason-registry.js");
test("each registry entry: japanese -> the injection exactly once; english -> no injection", () => {
  const reg = registered();
  assert.ok(reg.length >= 12, `the registry has the plan's generators (${reg.length})`);
  for (const e of reg) {
    const call = () => require(e.file)[e.export](...JSON.parse(JSON.stringify(e.sampleArgs)));
    const ja = withLang("japanese", call);
    assert.strictEqual(typeof ja, "string", `${e.export} returns a string for its sampleArgs`);
    assert.strictEqual(count(ja, JA), 1, `${e.export} carries the japanese injection once`);
    assert.strictEqual(count(withLang("english", call), "Respond to the user in"), 0, `${e.export} adds nothing under english`);
  }
});
caseEnd();

caseBegin("integrated-reason-single-injection", "hooks/supervisor-guard/format-integrated.js");
test("formatIntegratedReason: the injection appears exactly once for l2, l3 and both", () => {
  const { formatIntegratedReason } = require("../../hooks/supervisor-guard/format-integrated");
  const { formatL2ArmedReason } = require("../../hooks/lib/supervisor-report-format");
  withLang("japanese", () => {
    const l2 = formatL2ArmedReason("sentinel-hang", "sid", null, "agents/supervisor.md", "state.json", "sid");
    assert.strictEqual(count(l2, JA), 1, "fixture: the l2 reason is already injected");
    const l3 = "Audit verdict BLOCK: plan drift";
    const block = (source) => ({ decision: "block", source, reason: "fallback reason" });
    assert.strictEqual(count(formatIntegratedReason(block("both"), l2, l3), JA), 1, "both");
    assert.strictEqual(count(formatIntegratedReason(block("l2"), l2, null), JA), 1, "l2");
    assert.strictEqual(count(formatIntegratedReason(block("l3"), null, l3), JA), 1, "l3 (not injected today)");
    assert.strictEqual(count(formatIntegratedReason(block("l2"), null, null), JA), 1, "l2 fallback to arbitration.reason");
    assert.strictEqual(formatIntegratedReason({ decision: "allow" }, l2, l3), "", "allow stays empty");
  });
});
caseEnd();

caseBegin("bundled-reason-single-injection", "hooks/supervisor-guard.js");
test("the alert block with the bundled audit launch carries the injection exactly once (japanese)", () => {
  const s = S.scene(ROOT, "ja", { alert: { alert_phase: "pending", alert_armed_at: new Date().toISOString(), alert_retry_count: 0 } });
  const r = X.runHook("hooks/supervisor-guard.js", s.dir, X.stopInput(s.dir, s.sid, S.turns(S.PROMPTS[0])), "japanese");
  const reason = S.reasonOf(r);
  assert.ok(S.ALERT_MARK.test(reason), `alert block (${r.status} ${String(r.stdout).slice(0, 200)})`);
  assert.ok(S.hasLaunch(reason), "the audit launch section is bundled");
  assert.strictEqual(count(reason, JA), 1, "one injection for the whole bundled reason");
});
caseEnd();

caseBegin("agents-follow-conv-lang", "agents/supervisor.md");
test("supervisor.md: the fixed English ack is replaced (no line added); supervisor-audit.md Output names CONV_LANG", () => {
  const sup = fs.readFileSync(path.join(REPO, "agents", "supervisor.md"), "utf8");
  assert.ok(!sup.includes("Alert review complete — findings recorded to state; actionable summary surfaced by the Stop hook."),
    "the fixed English ack line is gone");
  const reporting = sup.split("### Reporting back")[1] || "";
  assert.ok(/CONV_LANG/.test(reporting.split(/\n### /)[0]), "Reporting back tells the agent to ack in the CONV_LANG language");
  assert.ok(sup.split("\n").length <= 114, "supervisor.md gains no line (113 today + trailing newline)");
  const aud = fs.readFileSync(path.join(REPO, "agents", "supervisor-audit.md"), "utf8");
  const output = (aud.split("\n## Output")[1] || "").split("\n## ")[0];
  assert.ok(/CONV_LANG/.test(output), "the Output section instructs CONV_LANG for the verdict summary and final reply");
  assert.ok(aud.split("\n").length <= 201, "supervisor-audit.md stays within the Pattern B HARD limit");
});
caseEnd();
