"use strict";
// bin/workflow/lib/jev-complexity-adapter/decisive.js — the gate's decisiveness hook for
// complexity-judge (#2677): Jev-adopted true signals short-circuit the judgment only when they
// already route every workflow step the judgment feeds to "high". Jev stage `complexity` feeds
// every routing step (persisted levels); outline / detail / write-tests / write-code feed their own.

const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { ROUTING_STEPS, JUDGED_SIGNAL_IDS, deriveStepLevel } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));
const { questionKey } = require("./questions.js");

const OWN_STAGES = Object.freeze(["outline", "detail", "write-tests", "write-code"]);

function routingStepsOf(jevStage) {
  if (jevStage === "complexity") return ROUTING_STEPS.slice();
  if (OWN_STAGES.includes(jevStage)) return [jevStage.replace(/-/g, "_")];
  return null;
}

// decidesAtStage(jevStage, adoptedKeys) -> true only when every mapped step derives "high".
function decidesAtStage(jevStage, adoptedKeys) {
  try {
    const steps = routingStepsOf(jevStage);
    if (!steps || !Array.isArray(adoptedKeys) || adoptedKeys.length === 0) return false;
    const idOf = {};
    for (const id of JUDGED_SIGNAL_IDS) idOf[questionKey(id)] = id;
    const ids = [];
    for (const k of adoptedKeys) {
      if (!Object.prototype.hasOwnProperty.call(idOf, k)) return false;
      ids.push(idOf[k]);
    }
    return steps.every((s) => deriveStepLevel(s, ids) === "high");
  } catch (_e) {
    return false;
  }
}

module.exports = { decidesAtStage };
