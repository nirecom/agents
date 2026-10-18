"use strict";
// Counts CONFIRM gate probes. Since #2681 the probe is in-process: probe.js calls
// hooks/lib/config-flag.js classifyConfigFlag at call time, so wrapping that export counts
// every probe. Only CONFIRM_* keys count. As a NODE_OPTIONS --require preload it appends one
// line per probe to CC_PROBE_LOG; required in-process, count() reads the running total.
const fs = require("fs");
const path = require("path");

const cf = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "config-flag.js"));
const LOG = process.env.CC_PROBE_LOG;
let n = 0;
if (!cf.__probeCounted) {
  const orig = cf.classifyConfigFlag;
  cf.classifyConfigFlag = function (name, ...rest) {
    if (/^CONFIRM_/.test(String(name))) {
      n += 1;
      try { if (LOG) fs.appendFileSync(LOG, String(name) + "\n"); } catch (_) { /* counting never changes the hook */ }
    }
    return orig.call(this, name, ...rest);
  };
  cf.__probeCounted = true;
}

module.exports = { count: () => n };
