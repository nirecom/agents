"use strict";
// `node -r` preload, loaded after spawn-stub.js: makes the dispatcher's worker-module
// lookup return null, which is its "worker is not implemented" path after the claim.
const path = require("path");
const registry = require(path.join(path.dirname(process.env.WD_SPAWN_MODULE), "registry.js"));

registry.loadModule = function nullModule() {
  return null;
};
