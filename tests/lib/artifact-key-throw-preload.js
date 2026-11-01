"use strict";
// tests/lib/artifact-key-throw-preload.js
// Tests: tests/lib/artifact-key-throw-preload.js
// Tags: test-infrastructure, shared-lib, supervisor-audit, pre-confirm-audit, preload, scope:common
// #2853: loaded with NODE_OPTIONS=--require into a hook or bin child. When CC_ARTIFACT_KEY_THROW=1,
// the plan-artifact key functions of hooks/lib/diff-fingerprint throw, so the pre-confirm audit
// judgment fails mid-way, the way an unreadable plan artifact makes it fail. The judgment's
// error exit (acceptedOnError) reads only the state file and the ledger, so it still answers.
const path = require("path");

if (process.env.CC_ARTIFACT_KEY_THROW === "1") {
  const fp = require(path.join(__dirname, "..", "..", "hooks", "lib", "diff-fingerprint"));
  const boom = (name) => () => { throw new Error(`fixture: ${name} failed (CC_ARTIFACT_KEY_THROW)`); };
  for (const name of ["computeArtifactKey", "computeFreshnessKey"]) {
    if (typeof fp[name] === "function") fp[name] = boom(name);
  }
}
