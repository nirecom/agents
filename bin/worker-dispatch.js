#!/usr/bin/env node
"use strict";
// bin/worker-dispatch.js
//
// Single entry point for every plain-script worker (#1643).
//
//   node bin/worker-dispatch.js <worker-name> <main-root> <payload-json-path>
//
// One entry point rather than six scripts is the point: the main-worktree guard
// acquires exactly ONE sanctioned identifier to reason about, instead of a
// growing family of per-worker paths it must keep in sync.
//
// argv carries only three values, none of them free text. The payload — commit
// bodies, PR titles, test arguments — arrives as a PLANS_DIR-resident JSON file,
// so nothing a human or an LLM typed ever has to survive the guard's argv
// inspection.
//
// Exit codes:
//   0  normal path, including every validation failure — the failure is REPORTED
//      on stdout in the worker's own output contract so the calling skill parses
//      one shape either way.
//   2  the invocation itself is unusable: wrong arity, unknown worker, or an
//      anchor that cannot be derived. There is no contract to render into yet.

const path = require("path");

const registry = require("./worker-dispatch/registry");
const { resolveAnchors } = require("./worker-dispatch/anchor");
const { loadPayload, validateStructure } = require("./worker-dispatch/payload");
const { validate } = require("./worker-dispatch/capability");
const fsguard = require("./worker-dispatch/fsguard");
const emit = require("./worker-dispatch/emit");

const USAGE = "usage: worker-dispatch.js <worker-name> <main-root> <payload-json-path>";

function fatal(message) {
  process.stderr.write(`worker-dispatch: ${message}\n${USAGE}\n`);
  process.exit(2);
}

// Write scopes are anchor-derived, with one exception: the backup directory is
// <main-root>/.worktree-backup/<branch>, and the branch only exists once the
// payload has been read. Capability validation has already proven the value is
// exactly that derivation, so lifting it into the fsguard context cannot widen
// what a worker may write — it only makes the declared scope resolvable.
function writeContext(entry, anchors, value) {
  const spec = entry.payloadSpec || {};
  for (const key of Object.keys(spec)) {
    if (spec[key].type === "derived-backup-dir") {
      return Object.assign({}, anchors, { backupDir: value[key] || null });
    }
  }
  return anchors;
}

function main() {
  const argv = process.argv.slice(2);

  // Step 1 — argv arity. Fixed at three; a worker never gets a variadic tail.
  if (argv.length !== 3) fatal(`expected 3 arguments, got ${argv.length}`);
  const [workerName, mainRootArg, payloadPathArg] = argv;

  // Step 2 — worker-name enum. Own-property lookup only, so `__proto__` and
  // friends cannot masquerade as a registered worker.
  const entry = registry.get(workerName);
  if (entry === null) fatal(`unknown worker (expected one of: ${registry.names.join(", ")})`);

  // Step 3 — trust anchors. Derived from this module's own location and from
  // git, never from the caller's environment or working directory.
  const anchors = resolveAnchors(mainRootArg);
  if (anchors.error !== null) fatal(anchors.error);

  // From here on every outcome is a rendered contract on stdout with exit 0.

  // Step 4 — payload load. PLANS_DIR residency is checked before the file is read.
  let payload = null;
  try {
    payload = loadPayload(payloadPathArg, { plansDir: anchors.plansDir });
  } catch (e) {
    emit.failure(entry, `payload: ${e && e.message ? e.message : "could not be loaded"}`);
    return;
  }

  const structure = validateStructure(payload, entry);
  if (!structure.ok) {
    emit.failure(entry, `payload: ${structure.errors.join("; ")}`);
    return;
  }

  // Step 5 — capability validation. The second wall: the guard vetted the shape
  // of the invocation, this vets what the payload is allowed to cause.
  const capability = validate(payload, entry, anchors);
  if (!capability.ok) {
    emit.failure(entry, `capability: ${capability.errors.join("; ")}`);
    return;
  }

  // Step 6 — dispatch.
  const mod = registry.loadModule(workerName);
  if (mod === null) {
    emit.failure(entry, `worker '${workerName}' is not implemented yet in this dispatcher`);
    return;
  }

  const writeCtx = writeContext(entry, anchors, capability.value);

  let result = null;
  try {
    result = mod.run(capability.value, {
      anchors,
      entry,
      workerName,
      fsguard: {
        assertWritable: (target) => fsguard.assertWritable(workerName, target, writeCtx),
        writeFile: (target, data) => fsguard.writeFile(workerName, target, data, writeCtx),
        mkdir: (target) => fsguard.mkdir(workerName, target, writeCtx),
      },
      path,
    });
  } catch (e) {
    emit.failure(entry, `worker error: ${e && e.message ? e.message : "unknown error"}`);
    return;
  }

  emit.write(entry, result);
}

main();
