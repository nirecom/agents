#!/usr/bin/env bash
# Tests: feature/show/plan/link/settings/registration
# Tags: show-plan-link-settings-registration
# Integration test: verify show-plan-link.js is registered in settings.json
# under both the PostToolUse "Bash|runInTerminal|runCommands" matcher AND
# the existing "Write" matcher (preservation check).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$REPO_ROOT/settings.json"
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const post = (s.hooks && s.hooks.PostToolUse) || [];
  const bashEntry = post.find((e) => e.matcher === "Bash|runInTerminal|runCommands");
  if (!bashEntry) { console.error("FAIL: Bash matcher entry not found"); process.exit(1); }
  const hit = (bashEntry.hooks || []).some((h) => typeof h.command === "string" && h.command.includes("show-plan-link.js"));
  if (!hit) { console.error("FAIL: show-plan-link.js not registered under Bash matcher"); process.exit(1); }
  const writeEntry = post.find((e) => e.matcher === "Write");
  const writeHit = writeEntry && (writeEntry.hooks || []).some((h) => typeof h.command === "string" && h.command.includes("show-plan-link.js"));
  if (!writeHit) { console.error("FAIL: show-plan-link.js missing from Write matcher"); process.exit(1); }
  console.log("PASS: show-plan-link.js registered on both Bash and Write matchers");
' "$SETTINGS"
