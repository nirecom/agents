"use strict";
// ESLint flat config for hooks/, bin/ and tests/ (#2739). Run it through `node bin/run-eslint <path>`.
// The three noisy rules stay at warn until the existing violations are cleared; no-new-func and
// no-eval are errors so the existing disable directives for them stay in use.
const js = require("@eslint/js");
const globals = require("globals");
const { nodeShebangGlobs } = require("./bin/lib/eslint-node-scripts.js");

const DIRS = ["hooks", "bin", "tests"];
const rules = {
  "no-unused-vars": "warn",
  "no-useless-assignment": "warn",
  "no-empty": "warn",
  "no-new-func": "error",
  "no-eval": "error",
};

module.exports = [
  { ignores: ["skills/synced/**", ".claude/worktrees/**", ".codegraph/**"] },
  { linterOptions: { reportUnusedDisableDirectives: "warn" } },
  {
    files: ["{hooks,bin,tests}/**/*.js", "{hooks,bin,tests}/**/*.cjs", ...nodeShebangGlobs(__dirname, DIRS)],
    ...js.configs.recommended,
    languageOptions: { ecmaVersion: "latest", sourceType: "commonjs", globals: globals.node },
    rules: { ...js.configs.recommended.rules, ...rules },
  },
  {
    files: ["{hooks,bin,tests}/**/*.mjs"],
    ...js.configs.recommended,
    languageOptions: { ecmaVersion: "latest", sourceType: "module", globals: globals.nodeBuiltin },
    rules: { ...js.configs.recommended.rules, ...rules },
  },
];
