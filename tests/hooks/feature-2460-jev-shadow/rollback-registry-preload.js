"use strict";
// Test-only preload (NODE_OPTIONS=--require=<this file>): loads hooks/lib/jev/registry.js with
// complexity-judge rolled back to mode "shadow", the data-only rollback the hook pair serves.
// Every other line of the shipped registry runs unchanged; a registry whose shape no longer
// carries the expected mode line fails the load instead of silently staying production.

const Module = require("module");
const path = require("path");

const TARGET = path.resolve(__dirname, "..", "..", "..", "hooks", "lib", "jev", "registry.js");
const MODE_LINE = /("complexity-judge": \{[^}]*?\bmode: )"production"/;
const same = (a, b) => (process.platform === "win32" ? a.toLowerCase() === b.toLowerCase() : a === b);

const compile = Module.prototype._compile;
Module.prototype._compile = function rollbackCompile(content, filename) {
  if (!same(path.resolve(filename), TARGET)) return compile.call(this, content, filename);
  if (!MODE_LINE.test(content)) throw new Error("rollback-registry-preload: complexity-judge production mode line not found");
  return compile.call(this, content.replace(MODE_LINE, '$1"shadow"'), filename);
};
