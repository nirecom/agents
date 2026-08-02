"use strict";

// #1780 round-5 (codex HIGH): realResolve() moved to hooks/lib/path-containment.js,
// the single containment implementation now shared with
// hooks/block-off-clearance-write/bash-target-context.js (CPR-2). This file
// stays as the re-export its existing requirers and tests already point at.
const { MAX_SYMLINK_HOPS, realResolve } = require("../../lib/path-containment");

module.exports = {
  MAX_SYMLINK_HOPS,
  realResolve,
};
