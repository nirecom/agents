"use strict";
// `node -r` preload, loaded after spawn-stub.js: makes the test-runner worker module
// throw from inside run(), which is the dispatcher's "worker error" path.
const mod = require(process.env.WD_SPAWN_MODULE);

mod.scriptExists = function throwingScriptExists() {
  throw new Error("stubbed worker failure");
};
