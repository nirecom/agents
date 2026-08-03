// hooks/block-clearance-token-write/bash-target-context.js
// Context-aware classification of a single Bash WRITE TARGET (a redirect target
// or an argv path candidate), for the block-clearance-token-write entrypoint.
//
// A bare basename test is not enough for two reasons, both confirmed bypasses:
//
//   N-1 (#1780) — the protected tail can be hidden by shell syntax the hook
//   sees BEFORE the shell resolves it. Backslash escapes and intra-word quoting
//   are handled by the Bash-word normalizer in ../lib/protected-basenames.js;
//   what is left here is VARIABLE SPLICING (`S=.workflow-off; … > <wf>/s1$S`).
//   The sibling case where the WHOLE argv token is `$NAME` was already covered
//   by bash-scan.js's VAR_REF_RE, but concatenation (`<wf>/s1$S`) and redirect
//   targets were not — an asymmetry (CPR-5). substituteAssignments() resolves
//   `$NAME` / `${NAME}` ANYWHERE inside the target against the same contiguous
//   preceding assignment chain, and anything still unresolved fails closed when
//   the chain mentions a protected name at all.
//
//   N-2 (#1780) — a PURE-WILDCARD target (`<wf>/*`, `<wf>/s1*`, `<wf>/???…`)
//   commits no literal character to the protected suffix, so the glob matcher in
//   ../lib/basename-glob-normalize.js deliberately reports it as a non-match
//   (otherwise `rm -rf build/*` would block). That named exception is only safe
//   while such a glob cannot land on a protected file — so the exception is
//   qualified here by DIRECTORY CONTAINMENT: a glob basename whose directory
//   resolves at/under getWorkflowDir() fails closed, regardless of literal
//   overlap. Directories outside the workflow dir are untouched, so ordinary
//   bulk operations keep working.
//
// Unresolvable directories deliberately fall back to "not contained" (approve):
// turning every relative glob into a block would over-block ordinary work, which
// is the failure mode this hook has regressed into before.
//
// Split into ./bash-target-context/{substitute,cwd-tracking,classify}.js under
// the file-split HARD limit (rules/coding/file-split.md) — this file is dispatch
// + re-export only. Dependency order is one-directional: substitute.js <-
// classify.js <- cwd-tracking.js.
"use strict";

const { substituteAssignments } = require("./bash-target-context/substitute");
const { commandCwd } = require("./bash-target-context/cwd-tracking");
const {
  resolveWorkflowDir,
  globTargetInsideWorkflowDir,
  dynamicTargetInsideWorkflowDir,
  textNamesPathInsideWorkflowDir,
  classifyBashWriteTarget,
} = require("./bash-target-context/classify");

module.exports = {
  substituteAssignments,
  commandCwd,
  resolveWorkflowDir,
  globTargetInsideWorkflowDir,
  dynamicTargetInsideWorkflowDir,
  textNamesPathInsideWorkflowDir,
  classifyBashWriteTarget,
};
