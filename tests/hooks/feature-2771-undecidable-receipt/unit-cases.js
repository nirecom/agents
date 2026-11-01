"use strict";
// Private case of tests/hooks/feature-2771-undecidable-receipt.js: unit checks of the undecidable.js
// module (anchoredTailOf, mayHavePresented, noticeFor). Requires the caller's isolate() pins first.
const path = require("path");
const R = require("../feature-2729-presentation-receipt/fixture");
const { U, A, T, BASH } = R;
const { THINK, names } = require("./helpers");

function undecidableModuleUnit(check) {
  const UD = R.tryRequire("hooks/stop-confirm-plan-guard/undecidable.js");
  if (UD.__missing) {
    check("undecidable.js loads", false, UD.__missing);
    return;
  }
  const TRd = require(path.join(R.ROOT, "hooks/lib/transcript-reader"));
  // tailFrom(entries) -> the tail readTail hands over: tailOf of one parse, entries of another.
  const tailFrom = (entries) => {
    const lines = entries.map((e) => JSON.stringify(e));
    return Object.assign(TRd.tailOf(TRd.parseLines(lines)), { lines, entries: TRd.parseLines(lines) });
  };
  const head = [U("go", "u-p")];
  const at = (entries) => { try { return UD.anchoredTailOf(tailFrom(head.concat(entries))); } catch (e) { return "threw:" + e.message; } };
  const anchoredTo = (r, uuid) => r && typeof r === "object" && r.lastAssistantEntry && r.lastAssistantEntry.uuid === uuid && r.lastAssistantEntry === r.lastTextEntry;
  check("anchoredTailOf: text entry last -> anchored to it", anchoredTo(at([A("a-t", T("x"))]), "a-t"), at([A("a-t", T("x"))]));
  const thinkTail = tailFrom(head.concat([A("a-t", T("x")), THINK("a-k")]));
  const got = UD.anchoredTailOf(thinkTail);
  check("anchoredTailOf: thinking-only entries after it -> anchored to the text entry", anchoredTo(got, "a-t"), got);
  check("anchoredTailOf returns a copy and leaves the tail as read", got !== thinkTail && thinkTail.lastAssistantEntry.uuid === "a-k", thinkTail.lastAssistantEntry);
  check("anchoredTailOf: redacted_thinking after it -> anchored", anchoredTo(at([A("a-t", T("x")), THINK("a-r", "redacted_thinking")]), "a-t"), "not anchored");
  check("anchoredTailOf: no text entry -> null", at([A("a-k", { type: "thinking", thinking: "x", signature: "s" })]) === null, "not null");
  check("anchoredTailOf: text entry without uuid -> null", at([A(null, T("x"))]) === null, "not null");
  check("anchoredTailOf: tool_use in the text entry -> null", at([A("a-t", T("x"), BASH("ls", "b1"))]) === null, "not null");
  check("anchoredTailOf: a later entry with tool_use -> null", at([A("a-t", T("x")), A("a-b", BASH("ls", "b1"))]) === null, "not null");
  check("anchoredTailOf: a later entry of an unknown content type -> null", at([A("a-t", T("x")), A("a-u", { type: "mystery" })]) === null, "not null");

  const s = R.sessionAt("outline", { tag: 1990 });
  const plansDir = process.env.WORKFLOW_PLANS_DIR;
  const mh = (markers, input) => { try { return Array.from(UD.mayHavePresented({ sid: s.sid, markers, input, plansDir }) || []); } catch (e) { return ["threw:" + e.message]; } };
  const byMarker = mh([{ session_id: s.sid, suffix: "outline", absPath: s.plan, ts: 1 }], {});
  check("mayHavePresented: a plan stage marker -> that stage", byMarker.includes("outline") && !byMarker.includes("intent"), byMarker);
  const byName = mh([], { last_assistant_message: `see ${s.sid}-intent.md` });
  check("mayHavePresented: an existing <sid>-<stage>.md named in the message -> that stage", byName.includes("intent") && !byName.includes("outline"), byName);
  check("mayHavePresented: a named artifact that does not exist -> nothing", mh([], { last_assistant_message: `see ${s.sid}-detail.md` }).length === 0, mh([], { last_assistant_message: `see ${s.sid}-detail.md` }));
  check("mayHavePresented: no marker, no name -> nothing", mh([], {}).length === 0, mh([], {}));

  const n1 = UD.noticeFor(["outline"]);
  check("noticeFor names the stage and carries no URL", names(n1, "outline") && !/https?:\/\//i.test(n1), n1);
  const n2 = UD.noticeFor(["intent", "detail"]);
  check("noticeFor names every stage it is given", names(n2, "intent") && names(n2, "detail") && !names(n2, "outline"), n2);
  check("noticeFor([]) is empty", !UD.noticeFor([]), UD.noticeFor([]));
}

module.exports = { undecidableModuleUnit };
