"use strict";
// Tests: hooks/lib/plan-link.js
// Tags: TL1, hooks, plan-link, render-model-context, turn-scope, confirm-echo, scope:issue-specific
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
