#!/usr/bin/env node
"use strict";
// bin/worker-dispatch.js — single entry point for every plain-script worker (#1643).
//   node bin/worker-dispatch.js <worker-name> <main-root> <payload-json-path>
// One entry point gives the main-worktree guard ONE sanctioned identifier. argv carries
// no free text: the payload is a JSON file published by bin/worker-dispatch-payload into
// <workflowDir>/<sid>.control/ (docs/architecture/claude-code/state-dirs.md).
// Exit codes:
//   0  normal path, including validation failures — REPORTED on stdout in the worker's
//      own output contract so the calling skill parses one shape either way.
//   1  the payload was already dispatched (a `.dispatched` marker exists), also reported.
//   2  the invocation itself is unusable: wrong arity, unknown worker, underivable anchor.

const fs = require("fs");
const path = require("path");

const registry = require("./worker-dispatch/registry");
const { resolveAnchors, realAbs } = require("./worker-dispatch/anchor");
const { locatePayload, loadPayload, validateStructure } = require("./worker-dispatch/payload");
const { validate } = require("./worker-dispatch/capability");
const fsguard = require("./worker-dispatch/fsguard");
const emit = require("./worker-dispatch/emit");
const { controlPath, getSessionControlDir } = require("../hooks/workflow-state/state-io/control-dir");

const USAGE = "usage: worker-dispatch.js <worker-name> <main-root> <payload-json-path>";

function fatal(message) {
  process.stderr.write(`worker-dispatch: ${message}\n${USAGE}\n`);
  process.exit(2);
}

function errText(e, fallback) {
  return e && e.message ? e.message : fallback;
}

// Write scopes are anchor-derived. The backup dir needs the payload's branch and the
// control dir the validated session id; both values are already proven derivations,
// so lifting them into the fsguard context only makes the declared scope resolvable.
function writeContext(entry, anchors, value, payloadSid) {
  const extra = {};
  const spec = entry.payloadSpec || {};
  for (const key of Object.keys(spec)) {
    if (spec[key].type === "derived-backup-dir") extra.backupDir = value[key] || null;
  }
  const sid = typeof value.session_id === "string" && value.session_id !== "" ? value.session_id : payloadSid;
  try {
    extra.controlDir = sid ? realAbs(getSessionControlDir(sid)) : null;
  } catch (_e) {
    extra.controlDir = null;
  }
  return Object.assign({}, anchors, extra);
}

// One-shot marker: `wx` makes the second dispatch of the same payload lose the race.
function markDispatched(sid, stem) {
  const marker = controlPath(sid, `${stem}.dispatched`, { forWrite: true });
  fs.writeFileSync(marker, `${new Date().toISOString()}\n`, { flag: "wx" });
}

const REPEAT = "this payload was already dispatched; publish a new one with a new --seq";

// Returns true when this process now owns the dispatch; otherwise reports and returns false.
function claimDispatch(entry, located) {
  try {
    if (fs.existsSync(controlPath(located.sid, `${located.stem}.dispatched`))) {
      emit.failure(entry, `payload: ${REPEAT}`);
      process.exitCode = 1;
      return false;
    }
    markDispatched(located.sid, located.stem);
    return true;
  } catch (e) {
    if (e && e.code === "EEXIST") {
      emit.failure(entry, `payload: ${REPEAT}`);
      process.exitCode = 1;
    } else {
      emit.failure(entry, `payload: dispatch marker could not be written: ${errText(e, "unknown error")}`);
    }
    return false;
  }
}

function main() {
  const argv = process.argv.slice(2);

  // Step 1 — argv arity. Fixed at three; a worker never gets a variadic tail.
  if (argv.length !== 3) fatal(`expected 3 arguments, got ${argv.length}`);
  const [workerName, mainRootArg, payloadPathArg] = argv;

  // Step 2 — worker-name enum, own-property lookup only (`__proto__` is not a worker).
  const entry = registry.get(workerName);
  if (entry === null) fatal(`unknown worker (expected one of: ${registry.names.join(", ")})`);

  // Step 3 — trust anchors, from this module's location and git, never the environment.
  const anchors = resolveAnchors(mainRootArg);
  if (anchors.error !== null) fatal(anchors.error);

  // Step 4 — payload location, then load. Residency is checked before the file is read.
  let located = null;
  let payload = null;
  try {
    located = locatePayload(payloadPathArg, { stateRoots: anchors.stateRoots, plansDir: anchors.plansDir });
    payload = loadPayload(located.abs);
  } catch (e) {
    emit.failure(entry, `payload: ${errText(e, "could not be loaded")}`);
    return;
  }

  const structure = validateStructure(payload, entry);
  if (!structure.ok) {
    emit.failure(entry, `payload: ${structure.errors.join("; ")}`);
    return;
  }
  if (located.sid !== null && payload.session_id !== undefined && payload.session_id !== located.sid) {
    emit.failure(entry, "payload: session_id does not match the session of the payload path");
    return;
  }

  // Step 5 — one-shot dispatch marker, written before any worker code runs. A legacy
  // PLANS_DIR payload without a <sid>-worker- name has no session to mark (temporary shim).
  if (located.sid !== null && !claimDispatch(entry, located)) return;

  // Step 6 — capability validation: what the payload is allowed to cause.
  const payloadAnchors = Object.assign({}, anchors, { payloadSid: located.sid });
  const capability = validate(payload, entry, payloadAnchors);
  if (!capability.ok) {
    emit.failure(entry, `capability: ${capability.errors.join("; ")}`);
    return;
  }

  // Step 7 — dispatch.
  const mod = registry.loadModule(workerName);
  if (mod === null) {
    emit.failure(entry, `worker '${workerName}' is not implemented yet in this dispatcher`);
    return;
  }

  const writeCtx = writeContext(entry, anchors, capability.value, located.sid);

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
        renameWithin: (tmp, dst) => fsguard.renameWithin(workerName, tmp, dst, writeCtx),
      },
      path,
    });
  } catch (e) {
    emit.failure(entry, `worker error: ${errText(e, "unknown error")}`);
    return;
  }

  emit.write(entry, result);
}

main();
