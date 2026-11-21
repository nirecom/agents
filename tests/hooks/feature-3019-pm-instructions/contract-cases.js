"use strict";
// Contract cases of tests/hooks/feature-3019-pm-instructions.js (#3019): the real SSOT md and the skill
// text that calls bin/pm-instructions (text-only checks of prompt files). No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const W8 = require("./world");

const { ROOT, SSOT_MD, P, MAX_BYTES, CONTRACT, TIMING_KEYS, INTERIM_ISSUES, headingPairs, makeWorld, brief } = W8;
const PROMPT_HARD_LINES = 200;
const readMd = () => {
  assert.ok(fs.existsSync(SSOT_MD), "skills/_shared/pm-supervisor-duties.md does not exist");
  return fs.readFileSync(SSOT_MD, "utf8");
};
const skill = (name) => fs.readFileSync(path.join(ROOT, "skills", name, "SKILL.md"), "utf8");
// section(text, re) -> the text from the heading matching re up to the next heading of the same or a higher level.
function section(text, re) {
  const lines = text.split(/\r?\n/);
  const i = lines.findIndex((l) => re.test(l));
  if (i < 0) return null;
  const level = /^#+/.exec(lines[i])[0].length;
  const end = lines.findIndex((l, j) => j > i && /^#+ /.test(l) && /^#+/.exec(l)[0].length <= level);
  return lines.slice(i, end < 0 ? lines.length : end).join("\n");
}
const CALL_RE = /bin\/pm-instructions"?\s+--timing\s+([a-z-]+)/g;
const timingsIn = (text) => [...String(text).matchAll(CALL_RE)].map((m) => m[1]);

// realMd: the SSOT md carries every contract heading once, the interim markers, and stays within its limits.
function realMd(S) {
  test("contract-md: every contract H2 appears exactly once", () => {
    const { h2 } = headingPairs(readMd());
    for (const name of new Set(CONTRACT.map((c) => c.h2))) assert.strictEqual(h2.get(name), 1, `## ${name}: ${h2.get(name) || 0}`);
  });
  test("contract-md: every contract H2/H3 pair appears exactly once", () => {
    const { pairs } = headingPairs(readMd());
    for (const c of CONTRACT) assert.strictEqual(pairs.get(`${c.h2}/${c.h3}`), 1, `${c.h2} / ${c.h3}: ${pairs.get(`${c.h2}/${c.h3}`) || 0}`);
  });
  test("contract-md: [interim: #NNNN] markers name exactly the six follow-up issues", () => {
    const found = new Set([...readMd().matchAll(/\[interim: #(\d+)\]/g)].map((m) => Number(m[1])));
    assert.deepStrictEqual([...found].sort((a, b) => a - b), INTERIM_ISSUES);
  });
  test("contract-md: the glossary and the PM contact procedure are referenced, not restated", () => {
    const md = readMd();
    for (const ref of ["docs/glossary/user.md", "skills/_shared/pm-pre-pr-contact.md"]) assert.ok(md.includes(ref), `no reference to ${ref}`);
  });
  test(`contract-md: within the prompt HARD limit (${PROMPT_HARD_LINES} lines)`, () => {
    const n = readMd().split(/\r?\n/).length;
    assert.ok(n <= PROMPT_HARD_LINES, `${n} lines`);
  });
  const w = makeWorld(S, "real-md");
  const pmSid = P.uuid(0x30191001);
  const wf = P.uuid(0x30191002);
  w.pm(pmSid, P.pm({ tag: "PM-real", issues: [4951] }));
  w.plain(wf);
  w.intent(wf, ["#4951"]);
  for (const [label, sid] of [["pm", pmSid], ["workflow", wf]]) {
    test(`contract-md: the real ${label} bundle fits ${MAX_BYTES} bytes untruncated`, () => {
      const r = w.probe({ sid, deadline: "hook" });
      assert.strictEqual(typeof r.value, "string", brief(r));
      assert.ok(r.value.startsWith(`[pm-instructions role=${label} `), brief(r));
      assert.ok(!/truncated at/.test(r.value), "the real bundle was truncated");
      assert.ok(Buffer.byteLength(r.value, "utf8") <= MAX_BYTES,`${Buffer.byteLength(r.value, "utf8")} bytes`);
    });
  }
}

// One row per key duty: [recipient, timing, duty label, keyword regex]. A regex matches inside one line, so
// a wording tweak keeps it green while deleting the duty's directive turns it red.
const DUTIES = [
  ["pm", "session-start", "never answers a sentinel on the user's behalf", /never answer[^\n]*sentinel[^\n]*on behalf of the user/i],
  ["pm", "session-start", "stays out of a single issue's plan, tests and implementation", /never enter the plan, tests or implementation/i],
  ["pm", "session-start", "never instructs a workflow session another PM owns", /never instruct a workflow session[^\n]*another PM/i],
  ["pm", "session-start", "leaves fixed assignments to the user's skills", /fixed assignment[^\n]*only by the user/i],
  ["pm", "session-start", "checks a sender against the PM state", /check the sender against the PM state/i],
  ["pm", "session-start", "ends only through a /resume-session --from hand-over", /resume-session --from/],
  ["workflow", "issue-start", "never lets a PM proxy-answer a sentinel", /never let a PM[^\n]*sentinel/i],
  ["workflow", "issue-start", "rejects an instruction from a PM other than the assigned PM", /only from the assigned PM[^\n]*reject[^\n]*other PM/i],
  ["workflow", "issue-start", "does not trust a role=pm header alone", /role=pm[^\n]*assigned PM/],
  ["workflow", "issue-start", "contacts the assigned PM before PR creation", /pm-pre-pr-contact\.md/],
  ["workflow", "before-companions", "consults the PM before presenting companions", /consult the assigned PM[^\n]*companion/i],
  ["workflow", "before-plan-confirm", "emits the plan confirmation only after the PM's OK", /review the plan[^\n]*only after the PM's OK/i],
  ["workflow", "before-user-verification", "emits USER_VERIFIED only after the PM's OK", /USER_VERIFIED[^\n]*only after the PM's OK/],
  ["workflow", "after-final-report", "reports completion to the assigned PM", /report completion to the assigned PM/i],
];

// realDuties: the real md (no MD_ENV) rendered per recipient x timing carries each key duty's directive.
function realDuties(S) {
  const w = makeWorld(S, "real-duties");
  const sid = { pm: P.uuid(0x30191101), workflow: P.uuid(0x30191102) };
  w.pm(sid.pm, P.pm({ tag: "PM-duty", issues: [4961] }));
  w.plain(sid.workflow);
  w.intent(sid.workflow, ["#4961"]);
  const cache = new Map();
  const render = (recipient, timing) => {
    const k = `${recipient}/${timing}`;
    if (!cache.has(k)) cache.set(k, w.probe({ sid: sid[recipient], timing, deadline: "hook" }));
    return cache.get(k);
  };
  for (const [recipient, timing, label, re] of DUTIES) {
    test(`contract-duty ${recipient}/${timing}: ${label}`, () => {
      const r = render(recipient, timing);
      assert.strictEqual(typeof r.value, "string", brief(r));
      assert.ok(r.value.startsWith(`[pm-instructions role=${recipient} timing=${timing}]`), brief(r));
      assert.ok(re.test(r.value), `${re} not in the rendered block: ${brief(r)}`);
    });
  }
  test("contract-duty workflow/session-start: the hook bundle carries the proxy-sentinel ban and the other-PM rejection", () => {
    const r = render("workflow", "session-start");
    assert.strictEqual(typeof r.value, "string", brief(r));
    for (const [, timing, , re] of DUTIES) if (timing === "issue-start") assert.ok(re.test(r.value), `${re}: ${brief(r)}`);
  });
}

// skillCalls: each skill calls bin/pm-instructions at its timing (or references the md), with contract keys only.
function skillCalls() {
  test("skill-calls: every --timing value in the seven skills is a contract key", () => {
    for (const name of ["workflow-init", "clarify-intent", "resume-session", "session-close", "pm-init", "pm-add", "pm-remove"]) {
      for (const t of timingsIn(skill(name))) assert.ok(TIMING_KEYS.includes(t), `${name}: --timing ${t}`);
    }
  });
  test("skill-calls: workflow-init WI-2a calls session-start with the driver checkpoint", () => {
    const s = section(skill("workflow-init"), /^### WI-2a\b/);
    assert.ok(s, "no ### WI-2a section");
    assert.ok(timingsIn(s).includes("session-start"), s);
    assert.ok(s.includes("--checkpoint"), s);
  });
  test("skill-calls: clarify-intent calls before-companions", () => assert.ok(timingsIn(skill("clarify-intent")).includes("before-companions")));
  test("skill-calls: resume-session calls session-start", () => assert.ok(timingsIn(skill("resume-session")).includes("session-start")));
  test("skill-calls: session-close SC-7a sits between SC-7 and SC-8 and calls after-final-report", () => {
    const text = skill("session-close");
    const at = (re) => text.split(/\r?\n/).findIndex((l) => re.test(l));
    const [i7, i7a, i8] = [at(/^## SC-7 /), at(/^## SC-7a\b/), at(/^## SC-8\b/)];
    assert.ok(i7 >= 0 && i7a > i7 && i8 > i7a, `SC-7=${i7} SC-7a=${i7a} SC-8=${i8}`);
    assert.ok(timingsIn(section(text, /^## SC-7a\b/)).includes("after-final-report"));
  });
  test("skill-calls: pm-init calls session-start", () => assert.ok(timingsIn(skill("pm-init")).includes("session-start")));
  for (const name of ["pm-add", "pm-remove"]) {
    test(`skill-calls: ${name} references the PM session section of the SSOT md`, () => {
      const text = skill(name);
      assert.ok(text.includes("pm-supervisor-duties.md") && text.includes("PM session"), `${name} has no reference line`);
    });
  }
}

module.exports = { realMd, realDuties, skillCalls };
