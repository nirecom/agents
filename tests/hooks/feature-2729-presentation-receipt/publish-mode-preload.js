"use strict";
// NODE_OPTIONS --require preload for the #2729 receipt drivers. CC_PUBLISH_MODE picks what
// hooks/lib/plan-link.js sees from ./plan-sync (no git, no network):
//   published (default) | not-published | unknown-forge | host-mismatch | not-provisioned | plan-sync-off
// CC_FAULT breaks one seam for real: link-throws (plan-link linkForFile throws) |
// presented-throws (confirm-continuation presentedStages throws).
const Module = require("module");
const path = require("path");

const REMOTE = "https://example.invalid/test-owner/test-repo.git";
const BLOB = "https://example.invalid/test-owner/test-repo/blob/main/";
const MODE = process.env.CC_PUBLISH_MODE || "published";
const FAULT = process.env.CC_FAULT || "";

const stub = {
  resolveRemoteUrl: () => (MODE === "plan-sync-off" ? { value: "", loadFailed: false } : { value: REMOTE, loadFailed: false }),
  checkProvisioned: () => (MODE === "not-provisioned" ? { ok: false } : { ok: true, pushUrl: REMOTE }),
  readProjectHostState: () => (MODE === "host-mismatch" ? "host-mismatch" : "match"),
  resolveRemoteTarget: () => ({ type: MODE === "unknown-forge" ? "unknown" : "github" }),
  publishedBlobUrl: (_dir, abs) => (MODE === "not-published" ? null : BLOB + path.basename(String(abs))),
};

const patched = new WeakSet();
const orig = Module._load;
Module._load = function (request, parent, ...rest) {
  const fromPlanLink = parent && /[\\/]plan-link\.js$/.test(String(parent.filename || ""));
  if (fromPlanLink && /(^|[\\/])plan-sync(\.js)?$/.test(String(request))) return stub;
  const mod = orig.call(this, request, parent, ...rest);
  if (mod && typeof mod === "object" && !patched.has(mod)) {
    const req = String(request);
    if (FAULT === "link-throws" && /(^|[\\/])plan-link(\.js)?$/.test(req) && typeof mod.linkForFile === "function") {
      patched.add(mod);
      mod.linkForFile = () => { throw new Error("fault: linkForFile"); };
    }
    if (FAULT === "presented-throws" && /(^|[\\/])confirm-continuation(\.js)?$/.test(req) && typeof mod.presentedStages === "function") {
      patched.add(mod);
      mod.presentedStages = () => { throw new Error("fault: presentedStages"); };
    }
  }
  return mod;
};
