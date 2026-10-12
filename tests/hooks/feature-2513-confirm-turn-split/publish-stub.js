"use strict";
// NODE_OPTIONS --require preload for the publish-on cases of hook-driver.js: when
// hooks/lib/plan-link.js requires ./plan-sync, hand it a stub whose every plan is published at a
// synthetic example.invalid blob URL. No git, no network, no real remote.
const Module = require("module");
const path = require("path");

const REMOTE = "https://example.invalid/test-owner/test-repo.git";
const BLOB = "https://example.invalid/test-owner/test-repo/blob/main/";
const stub = {
  resolveRemoteUrl: () => ({ value: REMOTE, loadFailed: false }),
  checkProvisioned: () => ({ ok: true, pushUrl: REMOTE }),
  readProjectHostState: () => "match",
  resolveRemoteTarget: () => ({ type: "github" }),
  publishedBlobUrl: (_dir, abs) => BLOB + path.basename(String(abs)),
};

const orig = Module._load;
Module._load = function (request, parent, ...rest) {
  const fromPlanLink = parent && /[\\/]plan-link\.js$/.test(String(parent.filename || ""));
  if (fromPlanLink && /(^|[\\/])plan-sync(\.js)?$/.test(String(request))) return stub;
  return orig.call(this, request, parent, ...rest);
};
