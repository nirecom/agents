# shellcheck shell=bash
# Tests: settings.json, hooks/lib/settings-drift.js
# Tags: hook-registration, codegraph, prompt-hook, drift-detection, TL2, scope:issue-specific
# M25-M26 — the STATIC half: settings.json is read from disk, no hook is spawned.

# ===========================================================================
# M25: settings.json (static) -- exactly one UserPromptSubmit entry for the
# new hook, with timeout 5
# ===========================================================================
m25_out=$(node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const groups = (s.hooks && s.hooks.UserPromptSubmit) || [];
  let matches = [];
  for (const g of groups) {
    for (const h of (g.hooks || [])) {
      if (typeof h.command === 'string' && h.command.indexOf('codegraph-context-inject.js') >= 0) {
        matches.push(h);
      }
    }
  }
  process.stdout.write(JSON.stringify({ count: matches.length, timeouts: matches.map(m => m.timeout) }));
} catch (e) { process.stdout.write(JSON.stringify({ count: -1, error: e.message })); }
" "$SETTINGS_JSON" 2>/dev/null)
m25_count=$(json_field "$m25_out" "count")
m25_t0=$(json_field "$m25_out" "timeouts.0")
if [ "$m25_count" = "1" ] && [ "$m25_t0" = "5" ]; then
    pass "M25: settings.json has exactly one codegraph-context-inject.js UserPromptSubmit entry, timeout 5"
else
    fail "M25: expected count=1 timeout=5, got '$m25_out'"
fi

# ===========================================================================
# M25b: settings-drift.js detects a nested-command drop even when the
# matcher itself is still present (round-7 codex C9, S5-3b).
# ===========================================================================
M25B_SCRIPT="$TMPDIR_BASE/m25b.js"
cat > "$M25B_SCRIPT" <<'M25BEOF'
const fs = require("fs");
const path = require("path");
const AGENTS_DIR = process.argv[2];
const HOME_DIR = process.argv[3];

const assemblyPath = path.join(AGENTS_DIR, "install", "lib", "settings-assembly.js");
const assembly = require(assemblyPath);
const origBuild = assembly.buildAssembledSettings;

const built = origBuild({ agentsRoot: AGENTS_DIR });
const deployed = JSON.parse(JSON.stringify(built.settings));
// Deployed side: drop OUR new command from its UserPromptSubmit group (matcher
// count is unaffected -- exactly the nested-command drop S5-3b must catch).
const OURS = "codegraph-context-inject.js";
for (const g of (deployed.hooks && deployed.hooks.UserPromptSubmit) || []) {
  g.hooks = (g.hooks || []).filter((h) => typeof h.command !== "string" || h.command.indexOf(OURS) < 0);
}

// Expected side: patch the module's export so detectDrift's OWN internal
// require() (same resolved path, same module-cache entry) sees a 5th command
// even though settings.json on disk does not carry it yet.
assembly.buildAssembledSettings = function (opts) {
  const b = origBuild(opts);
  const settings = JSON.parse(JSON.stringify(b.settings));
  const groups = (settings.hooks && settings.hooks.UserPromptSubmit) || [];
  if (groups[0]) {
    const already = (groups[0].hooks || []).some((h) => typeof h.command === "string" && h.command.indexOf(OURS) >= 0);
    if (!already) {
      groups[0].hooks = groups[0].hooks || [];
      groups[0].hooks.push({ type: "command", command: 'node "$AGENTS_CONFIG_DIR/hooks/codegraph-context-inject.js"', timeout: 5 });
    }
  }
  return { settings, generatorError: b.generatorError };
};

fs.mkdirSync(path.join(HOME_DIR, ".claude"), { recursive: true });
fs.writeFileSync(path.join(HOME_DIR, ".claude", "settings.json"), JSON.stringify(deployed, null, 2));

const driftPath = path.join(AGENTS_DIR, "hooks", "lib", "settings-drift.js");
const { detectDrift } = require(driftPath);
const result = detectDrift({ homeDir: HOME_DIR });
process.stdout.write(JSON.stringify(result));
M25BEOF
M25B_HOME="$TMPDIR_BASE/m25b-home"; mkdir -p "$M25B_HOME"
m25b_out=$(node "$M25B_SCRIPT" "$(to_node_path "$AGENTS_DIR")" "$(to_node_path "$M25B_HOME")" 2>&1)
m25b_drifted=$(json_field "$m25b_out" "drifted")
m25b_missing=$(json_field "$m25b_out" "missingHooks.UserPromptSubmit.0")
if [ "$m25b_drifted" = "true" ] && printf '%s' "$m25b_missing" | grep -qF "codegraph-context-inject.js"; then
    pass "M25b: nested command drop under an unchanged matcher is reported as drift"
else
    fail "M25b: drifted='$m25b_drifted' missing='$m25b_missing' raw='$m25b_out'"
fi

# ===========================================================================
# M26: settings.json (static, negative guard) -- our command string never
# contains the upstream uninstall-sweep needles
# ===========================================================================
if [ "$m25_count" = "1" ]; then
    m26_cmd=$(node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
for (const g of (s.hooks && s.hooks.UserPromptSubmit) || []) {
  for (const h of (g.hooks || [])) {
    if (typeof h.command === 'string' && h.command.indexOf('codegraph-context-inject.js') >= 0) {
      process.stdout.write(h.command);
    }
  }
}
" "$SETTINGS_JSON" 2>/dev/null)
    if ! printf '%s' "$m26_cmd" | grep -qF "codegraph prompt-hook" && ! printf '%s' "$m26_cmd" | grep -qF "codegraph.cmd prompt-hook"; then
        pass "M26: command string carries neither uninstall-sweep needle"
    else
        fail "M26: command '$m26_cmd' contains a PROMPT_HOOK_FORMS needle"
    fi
else
    fail "M26: no codegraph-context-inject.js entry found to check (see M25)"
fi
