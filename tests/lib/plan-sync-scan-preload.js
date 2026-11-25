"use strict";
// tests/lib/plan-sync-scan-preload.js
// Tests: tests/lib/plan-sync-scan-preload.js
// Tags: scope:issue-specific, shared-lib, plan-sync, fixture, scan-outbound
// #3150: a hook started as a child process reaches the plan-sync scan gate without deps.scanEntry, so the
// gate would run bin/scan-outbound.sh of this repository and read the developer's real blocklist (rc 4 ->
// scan-unavailable on a host without one). Production has no override on purpose; a test therefore loads this
// file with `node --require` (NODE_OPTIONS). When PS_SCAN_BOX names a directory, the gate's
// `bash <repo>/bin/scan-outbound.sh --manifest` launch is redirected to a scanner copy in that directory,
// built here on first use outside any git repository and reading one synthetic blocklist only.
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

const BOX = process.env.PS_SCAN_BOX;
if (BOX) {
  const REPO = path.resolve(__dirname, "..", "..");
  const ENTRY = path.join(BOX, "bin", "scan-outbound.sh");
  const COPY = ["bin/scan-outbound.sh", "bin/scan-outbound.d", "bin/lib", "hooks/lib"];
  const norm = (p) => path.resolve(String(p)).replace(/\\/g, "/").toLowerCase();
  const ensureBox = () => {
    if (fs.existsSync(ENTRY)) return;
    for (const rel of COPY) {
      if (fs.existsSync(path.join(REPO, rel))) fs.cpSync(path.join(REPO, rel), path.join(BOX, rel), { recursive: true });
    }
    fs.writeFileSync(path.join(BOX, ".private-info-blocklist"), "f3150-fixture-never-present-token\n");
  };
  const realSpawnSync = cp.spawnSync;
  cp.spawnSync = function spawnSync(cmd, args, opts) {
    const isGate = cmd === "bash" && Array.isArray(args) && args[1] === "--manifest"
      && norm(args[0]) === norm(path.join(REPO, "bin", "scan-outbound.sh"));
    if (isGate) {
      ensureBox();
      args = [ENTRY.replace(/\\/g, "/")].concat(args.slice(1));
    }
    return realSpawnSync.call(this, cmd, args, opts);
  };
}
