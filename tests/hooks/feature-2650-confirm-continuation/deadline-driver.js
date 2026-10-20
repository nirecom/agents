"use strict";
// #2729: pickContinuationStage (one candidate only, else null) is replaced by presentedStages
// (every presented stage) plus continuationStage(presented, currentStage), which picks the stage
// the Stop hook asks to echo. T1-T5 drive continuationStage directly; the probe deadline itself
// stays covered by feature-stop-guard-layer2 T6. Prints PASS|name / FAIL|name|detail lines.
const X = require("./fixture");

const { show, check } = X;
const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
if (CC.__missing || typeof CC.continuationStage !== "function") {
  check("hooks/lib/confirm-continuation.js exports continuationStage", false, "not implemented: " + (CC.__missing || "no export"));
  process.exit(0);
}

// el(stage, linked) -> one presentedStages element; linked=false is the not-published case.
const el = (stage, linked) => ({ stage, absPath: `/plans/s-${stage}.md`, reason: linked === false ? "not-published" : "plan-sync-off",
  receiptLink: linked === false ? null : { kind: "path", value: `/plans/s-${stage}.md` }, contentSha: "a".repeat(64) });
// pick(presented, current) -> the chosen stage name, or null (accepts a stage string or an element).
function pick(presented, current) {
  let g;
  try { g = CC.continuationStage(presented, current); } catch (e) { return { threw: e.message }; }
  if (g === null || g === undefined) return null;
  return typeof g === "string" ? g : (g && g.stage) || g;
}

check("T1 three presented stages — the current step's stage is chosen", pick([el("intent"), el("outline"), el("detail")], "outline") === "outline",
  show(pick([el("intent"), el("outline"), el("detail")], "outline")));
check("T2 two presented stages, neither current — null", pick([el("intent"), el("outline")], "detail") === null,
  show(pick([el("intent"), el("outline")], "detail")));
check("T3 one presented stage, not the current one — that stage", pick([el("intent")], "outline") === "intent", show(pick([el("intent")], "outline")));
check("T4 the current stage is presented but unpublished (no receiptLink) — not chosen", pick([el("outline", false), el("intent")], "outline") === "intent",
  show(pick([el("outline", false), el("intent")], "outline")));
check("T5 nothing presented — null", pick([], "intent") === null, show(pick([], "intent")));
check("T5 only unpublished stages — null", pick([el("intent", false)], "intent") === null, show(pick([el("intent", false)], "intent")));
