# group3-settings.sh — G3-T1..T4: settings.json static check + assemble-settings.js integration.
# Sourced after helpers.sh; inherits all variables and functions.

# ============================================================================
# Group 3: settings.json static check — lang-inject.js registration
# ============================================================================

echo "=== Group 3: settings.json — lang-inject.js registration ==="

if [ ! -f "$SETTINGS_JSON" ]; then
    skip "G3: settings.json not found"
else
    # G3-T1: UserPromptSubmit array contains lang-inject.js entry
    _found=$(node -e "
try {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync('$(to_node_path "$SETTINGS_JSON")', 'utf8'));
  const hooks = s.hooks || {};
  const ups = hooks.UserPromptSubmit || [];
  let found = false;
  for (const entry of ups) {
    for (const h of (entry.hooks || [])) {
      if (h.command && h.command.includes('lang-inject.js')) { found = true; break; }
    }
  }
  process.stdout.write(found ? 'yes' : 'no');
} catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)
    if [ "$_found" = "yes" ]; then
        pass "G3-T1: settings.json UserPromptSubmit registers lang-inject.js"
    else
        fail "G3-T1: settings.json does NOT register lang-inject.js (RED until write-code). found=$_found"
    fi

    # G3-T2: settings.json is valid JSON (regression guard)
    _valid_json=$(node -e "
try {
  const fs = require('fs');
  JSON.parse(fs.readFileSync('$(to_node_path "$SETTINGS_JSON")', 'utf8'));
  process.stdout.write('yes');
} catch (e) { process.stdout.write('no:' + e.message); }
" 2>/dev/null)
    if [ "$_valid_json" = "yes" ]; then
        pass "G3-T2: settings.json is valid JSON"
    else
        fail "G3-T2: settings.json parse error: $_valid_json"
    fi

    # G3-T3: lang-inject.js entry has type=command and numeric timeout
    _entry_ok=$(node -e "
try {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync('$(to_node_path "$SETTINGS_JSON")', 'utf8'));
  const hooks = s.hooks || {};
  const ups = hooks.UserPromptSubmit || [];
  let ok = false;
  for (const entry of ups) {
    for (const h of (entry.hooks || [])) {
      if (h.command && h.command.includes('lang-inject.js')) {
        if (h.type === 'command' && typeof h.timeout === 'number') ok = true;
      }
    }
  }
  process.stdout.write(ok ? 'yes' : 'no');
} catch (e) { process.stdout.write('error'); }
" 2>/dev/null)
    if [ "$_entry_ok" = "yes" ]; then
        pass "G3-T3: lang-inject.js entry has type=command and numeric timeout"
    else
        fail "G3-T3: lang-inject.js entry missing type or timeout (RED until write-code). got=$_entry_ok"
    fi

    # G3-T4 [Integration]: assembled ~/.claude/settings.json registers lang-inject.js.
    # NON-DESTRUCTIVE: install/assemble-settings.js writes to os.homedir()/.claude/
    # settings.json. os.homedir() honors HOME/USERPROFILE (verified on win32), so we
    # redirect it to a temp dir. The source (agents/settings.json) is read from the
    # real repo, and only the output is redirected — the real ~/.claude/settings.json
    # is never touched. In RED this fails because the source settings.json lacks the
    # UserPromptSubmit lang-inject.js entry yet (assemble only concats existing hooks).
    ASSEMBLE_SETTINGS="$AGENTS_DIR/install/assemble-settings.js"
    if [ ! -f "$ASSEMBLE_SETTINGS" ]; then
        skip "G3-T4: install/assemble-settings.js not found"
    else
        FAKE_HOME="$TMPDIR_BASE/assemble-home-$$"
        mkdir -p "$FAKE_HOME"
        FAKE_HOME_NODE="$(to_node_path "$FAKE_HOME")"
        HOME="$FAKE_HOME_NODE" USERPROFILE="$FAKE_HOME_NODE" \
            run_with_timeout 30 node "$ASSEMBLE_SETTINGS" >/dev/null 2>&1
        _assemble_rc=$?
        _assembled_out="$FAKE_HOME_NODE/.claude/settings.json"
        if [ "$_assemble_rc" -ne 0 ]; then
            fail "G3-T4: assemble-settings.js exited non-zero ($_assemble_rc)"
        else
            _asm_found=$(node -e "
try {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const ups = (s.hooks || {}).UserPromptSubmit || [];
  let found = false;
  for (const entry of ups) {
    for (const h of (entry.hooks || [])) {
      if (h.command && String(h.command).includes('lang-inject.js')) { found = true; break; }
    }
  }
  process.stdout.write(found ? 'yes' : 'no');
} catch (e) { process.stdout.write('error:' + e.message); }
" "$_assembled_out" 2>/dev/null)
            if [ "$_asm_found" = "yes" ]; then
                pass "G3-T4: assembled settings.json UserPromptSubmit registers lang-inject.js"
            else
                fail "G3-T4: assembled settings.json does NOT register lang-inject.js (RED until write-code). found=$_asm_found"
            fi
        fi
    fi
fi

echo ""
