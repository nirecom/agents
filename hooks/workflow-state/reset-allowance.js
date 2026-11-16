"use strict";
// Reset allowance for RESET_FROM_<step> (#2852): re-exports only (Pattern A).
// Rules: ./reset-allowance/{forward,replay,decide}.js; wording: ./reset-allowance/reason-block.js.

const { isForwardAt } = require("./reset-allowance/forward");
const { ALLOWANCE, replayResets } = require("./reset-allowance/replay");
const { decideReset } = require("./reset-allowance/decide");
const { allowReason, askReason } = require("./reset-allowance/reason-block");

module.exports = { ALLOWANCE, decideReset, isForwardAt, replayResets, allowReason, askReason };
