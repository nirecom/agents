#!/usr/bin/env node
"use strict";
// install/lib/rtk-config-deploy.js — write RTK's config.toml on first install.
// Idempotent and non-destructive: an existing file is left untouched, and any
// failure is a warning, never a hard error (exit 0 always).

const fs = require("fs");
const os = require("os");
const path = require("path");

// RTK's own default config, verbatim from `rtk config --create` on v0.48.0.
// RTK deserializes each declared TOML section with every field required (no
// per-field defaults), so a partial section fails to parse — this must stay the
// complete default, not a hand-trimmed subset. The pre-v0.48 `[retriever]` /
// bare-`[tee]` schema this file used to write is rejected by v0.48.0 with a
// "missing field `mode`" parse error, which is what broke `rtk config` (#2347).
const CONFIG_TOML = `[tracking]
enabled = true
history_days = 90

[display]
colors = true
emoji = true
max_width = 120

[filters]
ignore_dirs = [
    ".git",
    "node_modules",
    "target",
    "__pycache__",
    ".venv",
    "vendor",
]
ignore_files = [
    "*.lock",
    "*.min.js",
    "*.min.css",
]

[tee]
enabled = true
mode = "failures"
max_files = 20
max_file_size = 1048576

[telemetry]
enabled = false

[hooks]
exclude_commands = []
transparent_prefixes = []

[limits]
grep_max_results = 200
grep_max_per_file = 25
status_max_files = 15
status_max_untracked = 10
passthrough_max_chars = 2000
`;

// Signature of the obsolete pre-v0.48 schema this installer used to write. The
// [retriever] section does not exist in v0.48.0 and any config containing it is
// rejected by rtk, so its presence unambiguously marks a config we must migrate
// in place rather than skip as "already present".
const OBSOLETE_MARKER = "[retriever]";

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
      // Preserve any config that is not the obsolete schema — including a user's
      // own customizations. Overwrite only a config carrying OBSOLETE_MARKER,
      // which rtk cannot parse, so migrating it loses nothing that worked.
      if (!fs.readFileSync(target, "utf8").includes(OBSOLETE_MARKER)) {
        console.log(`RTK config already present: ${target}`);
        return 0;
      }
      fs.writeFileSync(target, CONFIG_TOML);
      console.log(`RTK config migrated from obsolete schema: ${target}`);
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
