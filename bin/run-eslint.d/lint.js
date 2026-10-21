"use strict";
// Lints the targets of one lint root (the directory holding eslint.config.*) through the ESLint
// Node API. An explicit file the config does not cover (ignored, no config, or no active rule —
// ESLint's default **/*.js block alone) is reported as not applicable instead of passing
// silently; directories go to lintFiles as is, under the config chosen for the directory itself
// (a nested eslint.config.* below it is not consulted).

const isActive = (setting) => {
  const severity = Array.isArray(setting) ? setting[0] : setting;
  return severity !== undefined && severity !== 0 && severity !== "off";
};

async function covered(eslint, file) {
  if (await eslint.isPathIgnored(file)) return false;
  const config = await eslint.calculateConfigForFile(file);
  if (!config) return false;
  return Object.values(config.rules || {}).some(isActive);
}

// lintGroup({ lintRoot, configFile, targets, eslintPath, write }) -> error count
async function lintGroup({ lintRoot, configFile, targets, eslintPath, write }) {
  const { ESLint } = require(eslintPath);
  const eslint = new ESLint({ cwd: lintRoot, overrideConfigFile: configFile });
  const patterns = [];
  for (const t of targets) {
    if (!t.isDir && !(await covered(eslint, t.path))) {
      write(`eslint not applicable — check skipped (${t.path}: not covered by ${configFile})\n`);
      continue;
    }
    patterns.push(t.path);
  }
  if (patterns.length === 0) return 0;
  const results = await eslint.lintFiles(patterns);
  const formatter = await eslint.loadFormatter("stylish");
  const text = await formatter.format(results);
  if (text) write(text.endsWith("\n") ? text : `${text}\n`);
  return results.reduce((sum, r) => sum + (r.errorCount || 0), 0);
}

module.exports = { lintGroup, isActive };
