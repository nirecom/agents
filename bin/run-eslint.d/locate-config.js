"use strict";
// Nearest eslint.config.* at or above a path, in ESLint 10's lookup order.
const fs = require("fs");
const path = require("path");

const CONFIG_NAMES = ["js", "mjs", "cjs", "ts", "mts", "cts"].map((ext) => `eslint.config.${ext}`);

// locateConfig(absPath, isDir) -> { lintRoot, configFile } | null
// lintRoot is the directory holding the found eslint.config.*.
function locateConfig(absPath, isDir) {
  let dir = isDir ? absPath : path.dirname(absPath);
  for (;;) {
    for (const name of CONFIG_NAMES) {
      const file = path.join(dir, name);
      if (fs.existsSync(file) && fs.statSync(file).isFile()) return { lintRoot: dir, configFile: file };
    }
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

module.exports = { locateConfig, CONFIG_NAMES };
