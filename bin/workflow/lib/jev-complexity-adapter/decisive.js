"use strict";
// bin/workflow/lib/jev-complexity-adapter/decisive.js — the gate's decisiveness hook for
// complexity-judge (#2677): Jev-adopted true signals short-circuit the judgment only when they
// already route every stage the judgment feeds to "high". Stage `complexity` feeds every
// routing stage (persisted levels); outline / detail / write-tests / write-code feed their own.

const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { ROUTING_STAGES, JUDGED_SIGNAL_IDS, deriveStageLevel } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));
const { questionKey } = require("./questions.js");

const OWN_STAGES = Object.freeze(["outline", "detail", "write-tests", "write-code"]);

function routingStagesOf(jevStage) {
  if (jevStage === "complexity") return ROUTING_STAGES.slice();
  if (OWN_STAGES.includes(jevStage)) return [jevStage.replace(/-/g, "_")];
  return null;
}

// decidesAtStage(jevStage, adoptedKeys) -> true only when every mapped stage derives "high".
function decidesAtStage(jevStage, adoptedKeys) {
  try {
    const stages = routingStagesOf(jevStage);
    if (!stages || !Array.isArray(adoptedKeys) || adoptedKeys.length === 0) return false;
    const idOf = {};
    for (const id of JUDGED_SIGNAL_IDS) idOf[questionKey(id)] = id;
    const ids = [];
    for (const k of adoptedKeys) {
      if (!Object.prototype.hasOwnProperty.call(idOf, k)) return false;
      ids.push(idOf[k]);
    }
    return stages.every((s) => deriveStageLevel(s, ids) === "high");
  } catch (_e) {
    return false;
  }
}

module.exports = { decidesAtStage };
