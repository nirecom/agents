#!/usr/bin/env node
"use strict";
// install/lib/rtk-config-deploy.js — write RTK's config.toml on first install.
// Idempotent and non-destructive: an existing file is left untouched, and any
// failure is a warning, never a hard error (exit 0 always).

const fs = require("fs");
const os = require("os");
const path = require("path");

const CONFIG_TOML = `[retriever]
enabled = true

[tee]
enabled = true
`;

function getConfigTomlPath() {
  if (process.env.RTK_CONFIG_TOML) return process.env.RTK_CONFIG_TOML;
  if (process.platform === "win32") {
    return path.join(process.env.APPDATA || "", "rtk", "config.toml");
  }
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "rtk", "config.toml");
  }
  const base = process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config");
  return path.join(base, "rtk", "config.toml");
}

function deploy() {
  let target;
  try {
    target = getConfigTomlPath();
    if (fs.existsSync(target)) {
      console.log(`RTK config already present: ${target}`);
      return 0;
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, CONFIG_TOML);
    console.log(`RTK config written: ${target}`);
    return 0;
  } catch (e) {
    process.stderr.write(`RTK config deploy warning: ${e && e.message}\n`);
    return 0;
  }
}

module.exports = { getConfigTomlPath, deploy, CONFIG_TOML };

if (require.main === module) {
  process.exit(deploy());
}
