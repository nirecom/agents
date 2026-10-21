"use strict";
// Tests: hooks/lib/plan-link.js
// Tags: TL1, hooks, plan-link, render-model-context, turn-scope, confirm-echo, scope:issue-specific, gate-duty, receipt-link
// #2650: renderModelContext's instruction line closes only the current turn with the plan-link
// line and forbids repeating it in later turns; the after-write variant names the CONFIRM echo
// only for a stage that asks for confirmation. The header, entry and lookup lines stay unchanged.
// TL3 gap: whether a real model follows the instruction (ends only the presentation turn with the
// plan-link line, never repeats it later or in the CONFIRM echo) is not verified here.
const { isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
after(() => restore());

const PL = require(path.join(__dirname, "..", "..", "hooks", "lib", "plan-link.js"));
const { renderModelContext, entryLine, PLAN_LINK_COMMAND, REASONS, REASON_TEXT } = PL;

const THIS_TURN_RE = /\bthis turn\b/i;
const LATER_TURNS_RE = /later turns?/i;
// The negation must bind to "repeat ... later turns" in one clause, not to any other sentence.
const NO_REPEAT_LATER_RE = /\b(?:do not|don't|never)\s+repeat\b[^.;]*\blater turns?\b/i;
const NEVER_CARRIES_RE = /never carries the line/;
const QUALIFIED_CONFIRM_ECHO_RE = /\b(?:when|if) the stage asks for confirmation\b[^.]*\bCONFIRM echo\b/i;
const LOOKUP_LINE = `When asked later where a plan is, run ${PLAN_LINK_COMMAND} and write its output as-is; never send the plan with SendUserFile.`;
const HEADER_AFTER_WRITE = "[plan-link] Plan artifact written:";
const HEADER_CONFIRM = "[plan-link] The plan being confirmed:";

const URL_ENTRY = { stage: "intent", url: "https://example.com/plans/a-intent.md", path: "C:\\plans\\a-intent.md" };
const NO_URL_ENTRY = { stage: "outline", path: "C:\\plans\\a-outline.md", reason: REASONS.PLAN_SYNC_OFF };
const ENTRIES = [URL_ENTRY, NO_URL_ENTRY];

const MODES = [
  { name: "after-write", opts: { when: "after-write" }, header: HEADER_AFTER_WRITE },
  { name: "after-write (opts omitted)", opts: undefined, header: HEADER_AFTER_WRITE },
  { name: "after-write (opts null)", opts: null, header: HEADER_AFTER_WRITE },
  { name: "after-write (opts {})", opts: {}, header: HEADER_AFTER_WRITE },
  { name: "after-write (when bogus)", opts: { when: "bogus" }, header: HEADER_AFTER_WRITE },
  { name: "after-write (when CONFIRM, case differs)", opts: { when: "CONFIRM" }, header: HEADER_AFTER_WRITE },
  { name: "confirm", opts: { when: "confirm" }, header: HEADER_CONFIRM },
];

// The instruction line sits between the entry lines and the lookup line.
const linesOf = (entries, opts) => renderModelContext(entries, opts).split("\n");
const instructionOf = (lines) => lines[lines.length - 2];

function assertTurnScoped(instr, label) {
  assert.match(instr, THIS_TURN_RE, `${label}: instruction scopes the line to this turn (got: ${instr})`);
  assert.match(instr, LATER_TURNS_RE, `${label}: instruction names later turns (got: ${instr})`);
  assert.match(instr, NO_REPEAT_LATER_RE, `${label}: instruction forbids repeating in later turns (got: ${instr})`);
}

const AFTER_WRITE_INSTR = instructionOf(linesOf(ENTRIES, { when: "after-write" }));
const CONFIRM_INSTR = instructionOf(linesOf(ENTRIES, { when: "confirm" }));
const NO_REPEAT_ROWS = [
  { label: "real after-write instruction", text: AFTER_WRITE_INSTR, matches: true },
  { label: "real confirm instruction", text: CONFIRM_INSTR, matches: true },
  {
    label: "inverted confirm instruction",
    text: "End this turn's last text block with each line above as-is; repeat it in later turns. The CONFIRM echo follows when prompted, or after the user's reply, and never carries the line.",
    matches: false,
  },
  {
    label: "inverted after-write instruction",
    text: "End this turn's last text block with each line above as-is so the user can open the plan; repeat it in later turns. When the stage asks for confirmation, the CONFIRM echo follows when prompted, or after the user's reply.",
    matches: false,
  },
];

for (const row of NO_REPEAT_ROWS) {
  test(`case 6 [${row.label}]: the no-repeat check ${row.matches ? "accepts" : "rejects"} it`, () => {
    if (row.matches) assert.match(row.text, NO_REPEAT_LATER_RE);
    else assert.doesNotMatch(row.text, NO_REPEAT_LATER_RE);
  });
}

for (const m of MODES.filter((x) => x.header === HEADER_AFTER_WRITE)) {
  test(`case 1 [${m.name}]: instruction closes only this turn and is not repeated in later turns`, () => {
    assertTurnScoped(instructionOf(linesOf(ENTRIES, m.opts)), m.name);
  });

  test(`case 3 [${m.name}]: the CONFIRM echo is named only for a stage that asks for confirmation`, () => {
    const instr = instructionOf(linesOf(ENTRIES, m.opts));
    assert.strictEqual(instr, AFTER_WRITE_INSTR, `${m.name}: the after-write variant is rendered`);
    assert.match(instr, QUALIFIED_CONFIRM_ECHO_RE, `${m.name}: the CONFIRM echo mention is qualified (got: ${instr})`);
    assert.doesNotMatch(instr, NEVER_CARRIES_RE, `${m.name}: the confirm-only clause is absent (got: ${instr})`);
  });
}

test("case 2 [confirm]: presentation turn only, not repeated later, CONFIRM echo never carries the line", () => {
  const instr = instructionOf(linesOf(ENTRIES, { when: "confirm" }));
  assertTurnScoped(instr, "confirm");
  assert.match(instr, NEVER_CARRIES_RE, `confirm: the CONFIRM echo never carries the line (got: ${instr})`);
});

for (const m of MODES) {
  test(`case 4 [${m.name}]: header, entry lines and lookup line are unchanged`, () => {
    const lines = linesOf(ENTRIES, m.opts);
    assert.strictEqual(lines.length, 5, `${m.name}: header + 2 entries + instruction + lookup (got ${lines.length})`);
    assert.strictEqual(lines[0], m.header);
    assert.strictEqual(lines[1], entryLine(URL_ENTRY));
    assert.strictEqual(lines[2], `${entryLine(NO_URL_ENTRY)} — ${REASON_TEXT[REASONS.PLAN_SYNC_OFF]}`);
    assert.strictEqual(lines[lines.length - 1], LOOKUP_LINE);
  });
}

for (const m of MODES) {
  for (const [label, entries] of [["not an array", null], ["string", "intent"], ["empty array", []]]) {
    test(`case 5 [${m.name}, entries ${label}]: header + instruction + lookup, turn-scoped`, () => {
      const lines = linesOf(entries, m.opts);
      assert.strictEqual(lines.length, 3, `${m.name}/${label}: 3 lines (got ${lines.length})`);
      assert.strictEqual(lines[0], m.header);
      assert.strictEqual(lines[2], LOOKUP_LINE);
      assertTurnScoped(lines[1], `${m.name}/${label}`);
    });
  }
}

// ── #2729 stage 2: the after-write duty follows each entry's gate (C3) ──────────────
const END_OF_TURN_RE = /End this turn's last text block/;
const SUMMARY_ONCE_RE = /summary/i;
const PUBLISH_CONFIRM_RE = /publish/i;
const withGate = (e, gate) => Object.assign({}, e, { gate });
const URL_OUTLINE = { stage: "outline", url: "https://example.com/plans/a-outline.md", path: "C:\\plans\\a-outline.md" };
const NOT_PUB = { stage: "detail", path: "C:\\plans\\a-detail.md", reason: REASONS.NOT_PUBLISHED };
const afterLine = (lines, e) => lines[lines.indexOf(entryLine(e)) + 1];
const publishConfirmLines = (lines) => lines.filter((l) => PUBLISH_CONFIRM_RE.test(l) && /CONFIRM/.test(l));

test("gate 1 [all OFF]: one summary-once duty, no end-of-turn duty", () => {
  const ctx = renderModelContext([withGate(URL_ENTRY, "OFF"), withGate(URL_OUTLINE, "OFF")], { when: "after-write" });
  assert.match(ctx, SUMMARY_ONCE_RE, `OFF: the summary-once duty is rendered (got: ${ctx})`);
  assert.doesNotMatch(ctx, END_OF_TURN_RE, `OFF: no end-of-turn duty (got: ${ctx})`);
  assert.strictEqual(ctx.split("\n").filter((l) => SUMMARY_ONCE_RE.test(l)).length, 1, `OFF: the duty appears once (got: ${ctx})`);
});

for (const gate of ["ON", "ERROR", undefined]) {
  test(`gate 2 [all ${gate || "unset"}]: the current end-of-turn instruction, once, at the end`, () => {
    const entries = [URL_ENTRY, URL_OUTLINE].map((e) => (gate ? withGate(e, gate) : e));
    const lines = linesOf(entries, { when: "after-write" });
    assert.strictEqual(lines.length, 5, `${gate}: header + 2 entries + instruction + lookup (got ${lines.length})`);
    assert.strictEqual(instructionOf(lines), AFTER_WRITE_INSTR, `${gate}: the ON wording is unchanged`);
    assert.doesNotMatch(lines.join("\n"), SUMMARY_ONCE_RE, `${gate}: no OFF wording`);
  });
}

test("gate 3 [OFF + ON mixed]: each entry line is followed by its own stage's duty", () => {
  const off = withGate(URL_ENTRY, "OFF");
  const on = withGate(URL_OUTLINE, "ON");
  const lines = linesOf([off, on], { when: "after-write" });
  assert.match(String(afterLine(lines, off)), SUMMARY_ONCE_RE, `OFF entry: summary-once duty right after it (got: ${lines.join(" | ")})`);
  assert.doesNotMatch(String(afterLine(lines, off)), END_OF_TURN_RE, "OFF entry: not the end-of-turn duty");
  assert.match(String(afterLine(lines, on)), /last text block/, `ON entry: end-of-turn duty right after it (got: ${lines.join(" | ")})`);
  assert.strictEqual(lines[lines.length - 1], LOOKUP_LINE);
});

test("gate 4 [ON + not-published]: a publish-before-CONFIRM sentence is added", () => {
  const lines = linesOf([withGate(NOT_PUB, "ON")], { when: "after-write" });
  assert.ok(publishConfirmLines(lines).length >= 1, `not-published ON: publish/CONFIRM sentence present (got: ${lines.join(" | ")})`);
  assert.ok(lines.some((l) => END_OF_TURN_RE.test(l)), "not-published ON: the end-of-turn duty stays");
});

for (const reason of [REASONS.PLAN_SYNC_OFF, REASONS.NOT_PROVISIONED, REASONS.HOST_MISMATCH]) {
  test(`gate 5 [ON + ${reason}]: no publish-before-CONFIRM sentence`, () => {
    const lines = linesOf([withGate({ stage: "intent", path: "C:\\plans\\a-intent.md", reason }, "ON")], { when: "after-write" });
    assert.deepStrictEqual(publishConfirmLines(lines), [], `${reason}: no publish/CONFIRM sentence`);
  });
}

test("gate 6 [confirm mode]: the confirm wording ignores the gate", () => {
  for (const gate of ["ON", "ERROR", "OFF"]) {
    const instr = instructionOf(linesOf([withGate(URL_ENTRY, gate), withGate(NO_URL_ENTRY, gate)], { when: "confirm" }));
    assert.strictEqual(instr, CONFIRM_INSTR, `confirm/${gate}: unchanged`);
  }
});

// ── #2729 stage 2: receiptLinkOf / UNPUBLISHABLE_REASONS (the link kind SSOT) ─────
const UNPUB = ["plan-sync-off", "not-provisioned", "host-mismatch", "no-project-host", "unknown-forge"];
const asArray = (v) => (v instanceof Set ? [...v] : Array.isArray(v) ? v : []);

test("receipt 1: UNPUBLISHABLE_REASONS is exactly the five no-URL environments", () => {
  assert.ok(PL.UNPUBLISHABLE_REASONS, "UNPUBLISHABLE_REASONS is exported");
  assert.deepStrictEqual(asArray(PL.UNPUBLISHABLE_REASONS).slice().sort(), UNPUB.slice().sort());
});

test("receipt 2: receiptLinkOf picks url, path or null", () => {
  assert.strictEqual(typeof PL.receiptLinkOf, "function", "receiptLinkOf is exported");
  const p = "C:\\plans\\a-intent.md";
  assert.deepStrictEqual(PL.receiptLinkOf({ url: URL_ENTRY.url, path: p }), { kind: "url", value: URL_ENTRY.url });
  for (const reason of UNPUB) {
    assert.deepStrictEqual(PL.receiptLinkOf({ path: p, reason }), { kind: "path", value: p }, reason);
  }
  assert.strictEqual(PL.receiptLinkOf({ path: p, reason: REASONS.NOT_PUBLISHED }), null, "not-published -> null");
  assert.strictEqual(PL.receiptLinkOf({ reason: REASONS.NO_ARTIFACT }), null, "no-artifact -> null");
  assert.strictEqual(PL.receiptLinkOf(null), null, "null -> null");
});
