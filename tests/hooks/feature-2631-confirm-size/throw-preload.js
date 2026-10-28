"use strict";
// throw-preload.js — loaded with `node -r` into a hook spawned by fixture.js (opts.preload): a
// require whose resolved file ends with F2631_THROW_MODULE throws, so the hook meets a module that
// fails to load. F2631_THROW_PARENT (optional) narrows it to requires made from a file ending with
// that suffix, so a module the hook also loads at start-up (state-io/core.js) fails only on the call
// path under test. Suffixes use "/" on every host.

const Module = require("module");

const target = process.env.F2631_THROW_MODULE || "";
const parentSuffix = process.env.F2631_THROW_PARENT || "";
const slash = (p) => String(p || "").replace(/\\/g, "/");

if (target) {
  const load = Module._load;
  Module._load = function patchedLoad(request, parent, isMain) {
    let resolved = "";
    try { resolved = slash(Module._resolveFilename(request, parent, isMain)); } catch (_) { resolved = ""; }
    const fromParent = !parentSuffix || (parent && slash(parent.filename).endsWith(parentSuffix));
    if (resolved.endsWith(target) && fromParent) {
      throw new Error(`throw-preload: require of ${target} refused (fixture)`);
    }
    return load.apply(this, arguments);
  };
}
