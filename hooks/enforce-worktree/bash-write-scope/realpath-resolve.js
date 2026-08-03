"use strict";

// realResolve() lives in hooks/lib/path-containment.js, the single
// containment implementation shared with
// hooks/block-clearance-token-write/bash-target-context.js (CPR-2). This file
// stays as the re-export existing requirers already point at.
const { MAX_SYMLINK_HOPS, realResolve } = require("../../lib/path-containment");

module.exports = {
  MAX_SYMLINK_HOPS,
  realResolve,
};
