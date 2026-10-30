"use strict";
// Comment-block review settings (#2507, D3): read from <cfgDir>/.env only — never the ambient
// value — because the review returns a blocking rc and an ambient COMMENT_BLOCK_ENFORCE=off or a
// raised threshold would be a one-word bypass. pre-commit's cfg dir ignores AGENTS_MAIN_ROOT.

const fs = require("fs");
const path = require("path");
const { toWindowsPath } = require("../branch-diff");
const { readEnvFile } = require("../load-env");
const { parseMaxLines } = require("../comment-block-scan");

const DEFAULT_EXTENSIONS_RAW = "js;sh;py";

// readConfig(cfgDir) -> { enforce, threshold, extensionsRaw }; an empty value takes the default.
function readConfig(cfgDir) {
  const map = readEnvFile(path.join(cfgDir, ".env")) || {};
  const value = (key, def) => (typeof map[key] === "string" && map[key] !== "" ? map[key] : def);
  return {
    enforce: value("COMMENT_BLOCK_ENFORCE", "on"),
    threshold: parseMaxLines(value("COMMENT_BLOCK_MAX_LINES", "10")),
    extensionsRaw: value("CODE_FILE_EXTENSIONS", DEFAULT_EXTENSIONS_RAW),
  };
}

// cliCfgDir(env, checkoutRoot) — the standalone CLI's .env dir, as bash _load_env_resolve chose it:
// a non-empty AGENTS_MAIN_ROOT alone, else the checkout's logical then physical path holding a .env.
// pre-commit never calls this; it passes its own cfg dir.
function cliCfgDir(env, checkoutRoot) {
  const root = String((env && env.AGENTS_MAIN_ROOT) || "").trim();
  if (root) return toWindowsPath(root);
  let physical = checkoutRoot;
  try {
    physical = fs.realpathSync(checkoutRoot);
  } catch {
    // An unresolvable checkout keeps its logical path.
  }
  return [checkoutRoot, physical].find((c) => fs.existsSync(path.join(c, ".env"))) || checkoutRoot;
}

module.exports = { readConfig, cliCfgDir };
