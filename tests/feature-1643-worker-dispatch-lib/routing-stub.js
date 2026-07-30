"use strict";
// tests/feature-1643-worker-dispatch-lib/routing-stub.js
//
// `node -r` preload for tests/feature-1643-worker-dispatch-routing.sh.
//
// It replaces bin/worker-dispatch/registry.js's `loadModule` so the dispatcher
// routes to a worker whose behaviour the test chooses, while argv parsing,
// anchor resolution, both validation walls and emit rendering stay real. That
// is the only way to reach the "a worker misbehaved" arm of the dispatcher: no
// real worker can be made to throw on demand without editing source.
//
// Environment:
//   WD_REGISTRY_MODULE  absolute path to bin/worker-dispatch/registry.js
//   WD_MODE             which misbehaviour to stage:
//                         throw-error   run() throws an Error
//                         throw-string  run() throws a non-Error value
//                         return-empty     run() returns {}
//                         return-null      run() returns null
//                         return-undefined run() returns nothing at all
//                         return-string    run() returns a non-object
//                         return-noisy     run() returns unsanitized field values

const registry = require(process.env.WD_REGISTRY_MODULE);

const MODES = {
  "throw-error": () => {
    throw new Error("boom inside the worker");
  },
  "throw-string": () => {
    throw "a bare string, not an Error";
  },
  "return-empty": () => ({}),
  "return-null": () => null,
  // A worker whose every branch falls off the end of the function — the most
  // likely way this happens by accident, and distinct from an explicit null.
  "return-undefined": () => {},
  "return-string": () => "not-an-object",
  "return-noisy": () => ({
    status: 'ok"with"quotes',
    summary: "line one\nline two",
    artifactPath: "",
  }),
};

registry.loadModule = function stubbedLoadModule() {
  const mode = process.env.WD_MODE;
  const fn = MODES[mode];
  if (typeof fn !== "function") throw new Error(`routing-stub: unknown WD_MODE ${mode}`);
  return { run: fn };
};
