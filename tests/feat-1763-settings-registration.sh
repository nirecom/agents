#!/usr/bin/env bash
# tests/feat-1763-settings-registration.sh
# Tests: settings.json, install/assemble-settings.js, hooks/issue-provenance-mint.js, hooks/block-clearance-token-write.js
# Tags: issue-create, provenance, settings, hook-registration, installer, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Claude Code actually loading the assembled settings.json and firing the hook.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#   (real-environment counterpart: tests/TL3-hook-issue-provenance-mint.sh)
#
# S10a/S11 — a hook that is written but not registered is dead code. Assert both the
# source settings.json and the installer-assembled ~/.claude/settings.json register
# issue-provenance-mint.js on UserPromptSubmit, and that the renamed clearance-token
# guard replaced block-off-clearance-write.js on PreToolUse (no dangling reference).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
SETTINGS="$AGENTS_DIR/settings.json"
ASSEMBLE="$AGENTS_DIR/install/assemble-settings.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# find_hook <settings-file> <event> <needle> → yes|no|error:...
find_hook() {
    node -e "
try {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const arr = ((s.hooks || {})[process.argv[2]]) || [];
  let found = false;
  for (const entry of arr) {
    for (const h of (entry.hooks || [])) {
      if (h.command && String(h.command).includes(process.argv[3])) { found = true; }
    }
  }
  process.stdout.write(found ? 'yes' : 'no');
} catch (e) { process.stdout.write('error:' + e.message); }" "$1" "$2" "$3" 2>/dev/null
}

# entry_shape <settings-file> <event> <needle> → ok|bad|error
entry_shape() {
    node -e "
try {
  const fs = require('fs');
  const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const arr = ((s.hooks || {})[process.argv[2]]) || [];
  let ok = false;
  for (const entry of arr) {
    for (const h of (entry.hooks || [])) {
      if (h.command && String(h.command).includes(process.argv[3])) {
        if (h.type === 'command' && typeof h.timeout === 'number') ok = true;
      }
    }
  }
  process.stdout.write(ok ? 'ok' : 'bad');
} catch (e) { process.stdout.write('error'); }" "$1" "$2" "$3" 2>/dev/null
}

SETTINGS_NODE="$(node_path "$SETTINGS")"

echo "=== R0: settings.json is valid JSON (regression guard) ==="
VJ=$(node -e "
try { JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.stdout.write('yes'); }
catch (e) { process.stdout.write('no:' + e.message); }" "$SETTINGS_NODE" 2>/dev/null)
[ "$VJ" = "yes" ] && pass "R0-settings-valid-json" || fail "R0-settings-valid-json" "$VJ"

echo ""
echo "=== R1: UserPromptSubmit registers issue-provenance-mint.js ==="
F=$(find_hook "$SETTINGS_NODE" UserPromptSubmit issue-provenance-mint.js)
if [ "$F" = "yes" ]; then
    pass "R1-mint-hook-registered"
else
    fail "R1-mint-hook-registered" "RED-EXPECTED: settings.json UserPromptSubmit has no issue-provenance-mint.js entry (got: $F)"
fi

echo ""
echo "=== R2: the entry has type=command and a numeric timeout ==="
S=$(entry_shape "$SETTINGS_NODE" UserPromptSubmit issue-provenance-mint.js)
if [ "$S" = "ok" ]; then
    pass "R2-mint-entry-shape"
else
    fail "R2-mint-entry-shape" "RED-EXPECTED: entry missing type=command / numeric timeout (got: $S)"
fi

echo ""
echo "=== R3: the command is resolved through \$AGENTS_CONFIG_DIR like its siblings (CPR-5) ==="
if grep -qF 'issue-provenance-mint.js' "$SETTINGS"; then
    if grep -F 'issue-provenance-mint.js' "$SETTINGS" | grep -q 'AGENTS_CONFIG_DIR'; then
        pass "R3-mint-uses-agents-config-dir"
    else
        fail "R3-mint-uses-agents-config-dir" "the hook path must be \$AGENTS_CONFIG_DIR-relative like every other hook entry"
    fi
else
    fail "R3-mint-uses-agents-config-dir" "RED-EXPECTED: issue-provenance-mint.js absent from settings.json"
fi

echo ""
echo "=== R4: the mint hook file exists and is a Node module ==="
MINT="$AGENTS_DIR/hooks/issue-provenance-mint.js"
if [ -f "$MINT" ]; then
    if "$RWT" 15 node --check "$MINT" >/dev/null 2>&1; then
        pass "R4-mint-hook-parses"
    else
        fail "R4-mint-hook-parses" "node --check failed on hooks/issue-provenance-mint.js"
    fi
else
    fail "R4-mint-hook-parses" "RED-EXPECTED: hooks/issue-provenance-mint.js not yet created"
fi

echo ""
echo "=== R5: PreToolUse registers block-clearance-token-write.js (renamed guard) ==="
F=$(find_hook "$SETTINGS_NODE" PreToolUse block-clearance-token-write.js)
if [ "$F" = "yes" ]; then
    pass "R5-clearance-token-guard-registered"
else
    fail "R5-clearance-token-guard-registered" "RED-EXPECTED: PreToolUse still lacks block-clearance-token-write.js (got: $F)"
fi

echo ""
echo "=== R6: the old block-off-clearance-write.js name is fully retired ==="
OLD_REFS=$(grep -rlF 'block-off-clearance-write' "$AGENTS_DIR/settings.json" "$AGENTS_DIR/hooks" "$AGENTS_DIR/install" 2>/dev/null | sed "s|^$AGENTS_DIR/||" | tr '\n' ' ')
if [ -z "$OLD_REFS" ]; then
    pass "R6-old-guard-name-retired"
else
    fail "R6-old-guard-name-retired" "RED-EXPECTED: dangling references to the old hook name remain in: $OLD_REFS"
fi

echo ""
echo "=== R7: the renamed guard file exists and the old file is gone ==="
NEW_GUARD="$AGENTS_DIR/hooks/block-clearance-token-write.js"
OLD_GUARD="$AGENTS_DIR/hooks/block-off-clearance-write.js"
if [ -f "$NEW_GUARD" ] && [ ! -f "$OLD_GUARD" ]; then
    pass "R7-guard-file-renamed"
elif [ -f "$NEW_GUARD" ] && [ -f "$OLD_GUARD" ]; then
    fail "R7-guard-file-renamed" "both the old and the new guard file exist — the rename must not leave a copy behind"
else
    fail "R7-guard-file-renamed" "RED-EXPECTED: hooks/block-clearance-token-write.js not yet created"
fi

echo ""
echo "=== R8 [integration]: the assembled ~/.claude/settings.json keeps both registrations ==="
# NON-DESTRUCTIVE: assemble-settings.js writes to os.homedir()/.claude/settings.json and
# os.homedir() honours HOME/USERPROFILE, so the output is redirected into a temp dir.
if [ ! -f "$ASSEMBLE" ]; then
    fail "R8-assembled-mint-registered"     "install/assemble-settings.js not found"
    fail "R9-assembled-clearance-registered" "install/assemble-settings.js not found"
else
    FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME"
    FAKE_HOME_NODE="$(node_path "$FAKE_HOME")"
    HOME="$FAKE_HOME_NODE" USERPROFILE="$FAKE_HOME_NODE" \
        "$RWT" 30 node "$ASSEMBLE" >"$WORK/assemble.out" 2>&1
    ARC=$?
    ASM="$FAKE_HOME_NODE/.claude/settings.json"
    if [ "$ARC" -ne 0 ]; then
        fail "R8-assembled-mint-registered"      "assemble-settings.js exited $ARC: $(head -n 2 "$WORK/assemble.out" | tr '\n' ' ')"
        fail "R9-assembled-clearance-registered" "assemble-settings.js exited $ARC"
    else
        A=$(find_hook "$ASM" UserPromptSubmit issue-provenance-mint.js)
        [ "$A" = "yes" ] && pass "R8-assembled-mint-registered" \
            || fail "R8-assembled-mint-registered" "RED-EXPECTED: the assembled settings.json lacks issue-provenance-mint.js (got: $A)"
        B=$(find_hook "$ASM" PreToolUse block-clearance-token-write.js)
        [ "$B" = "yes" ] && pass "R9-assembled-clearance-registered" \
            || fail "R9-assembled-clearance-registered" "RED-EXPECTED: the assembled settings.json lacks block-clearance-token-write.js (got: $B)"
    fi
fi

echo ""
echo "=== R10: the marker-bypass contract documents the new hook ==="
CONTRACT="$AGENTS_DIR/docs/architecture/claude-code/marker-bypass-contract.md"
if [ ! -f "$CONTRACT" ]; then
    fail "R10-contract-documents-hook" "docs/architecture/claude-code/marker-bypass-contract.md not found"
elif grep -qF 'block-clearance-token-write' "$CONTRACT"; then
    pass "R10-contract-documents-hook"
else
    fail "R10-contract-documents-hook" "RED-EXPECTED: the Honoring-hooks SSOT table still names the old guard"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
