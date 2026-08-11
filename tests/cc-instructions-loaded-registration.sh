#!/usr/bin/env bash
# tests/cc-instructions-loaded-registration.sh
# Tests: settings.json, install/assemble-settings.js, hooks/instructions-loaded-audit.js
# Tags: rules-injection, instructions-loaded, hook-registration, settings, installer, TL2, scope:common
#
# A hook that is never registered never fires, and every behavioural test in this
# series would still pass. This file asserts the wiring itself against the REPO's
# real settings.json and the real installer merge — not a fixture copy.
# Layer: TL2 (reads the real settings.json; runs the real assembler against a
# redirected HOME with a pre-flight proving the redirection took effect).
#
# TL3 gap (what this test does NOT catch):
# - Whether the running Claude Code build dispatches an event under exactly the
#   "InstructionsLoaded" spelling; a registration can be well-formed and still dead.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$AGENTS_DIR/settings.json"
ASSEMBLER="$AGENTS_DIR/install/assemble-settings.js"
HOOK="$AGENTS_DIR/hooks/instructions-loaded-audit.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

EVENT="InstructionsLoaded"
WANT_CMD='node "$AGENTS_CONFIG_DIR/hooks/instructions-loaded-audit.js"'
WANT_TIMEOUT=5

# --- Tier 1: the hook file itself must exist before its registration can mean
# anything. /write-code lands the hook and the settings.json entry together
# (detail plan S2-2 / S2-5). ---
MISSING=0
for f in "$HOOK" "$SETTINGS" "$ASSEMBLER"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (targets not yet implemented — detail plan S2-2 / S2-5)"
    exit 1
fi

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# --- R1: settings.json registers the event with the expected command and timeout ---
R1="$(node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const ev = ((s.hooks || {})[process.argv[2]]) || null;
if (!ev) { console.log('NO_EVENT'); process.exit(0); }
if (!Array.isArray(ev)) { console.log('NOT_ARRAY'); process.exit(0); }
const entries = ev.flatMap((g) => (g && Array.isArray(g.hooks)) ? g.hooks : []);
const mine = entries.filter((h) => h && typeof h.command === 'string'
  && h.command.includes('instructions-loaded-audit.js'));
if (mine.length === 0) { console.log('NO_ENTRY'); process.exit(0); }
if (mine.length > 1) { console.log('DUPLICATE:' + mine.length); process.exit(0); }
const h = mine[0];
console.log([
  'TYPE=' + h.type,
  'CMD_EXACT=' + (h.command === process.argv[3] ? 'yes' : 'no'),
  'CMD_B64=' + Buffer.from(h.command, 'utf8').toString('base64'),
  'TIMEOUT_NUM=' + (typeof h.timeout === 'number' ? 'yes' : 'no'),
  'TIMEOUT=' + h.timeout,
  'MATCHER=' + JSON.stringify(ev.map((g) => g.matcher)),
].join(' '));
" "$(node_path "$SETTINGS")" "$EVENT" "$WANT_CMD" 2>&1)"

rfield() { printf '%s' "$R1" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }
# The command contains spaces, so it travels base64-encoded through the space-
# separated report and is decoded only where the literal text is needed.
rcmd() { rfield CMD_B64 | base64 -d 2>/dev/null; }

case "$R1" in
    NO_EVENT)   fail "R1: settings.json has no \"$EVENT\" hooks key at all" ;;
    NOT_ARRAY)  fail "R1: settings.json \"$EVENT\" is not an array of matcher groups" ;;
    NO_ENTRY)   fail "R1: \"$EVENT\" exists but no entry invokes instructions-loaded-audit.js" ;;
    DUPLICATE*) fail "R1: instructions-loaded-audit.js is registered more than once ($R1)" ;;
    *)
        if [ "$(rfield TYPE)" != "command" ]; then
            fail "R1: want type=command, got '$(rfield TYPE)' — $R1"
        elif [ "$(rfield CMD_EXACT)" != "yes" ]; then
            fail "R1: command must be exactly [$WANT_CMD], got [$(rcmd)]"
        elif [ "$(rfield TIMEOUT_NUM)" != "yes" ]; then
            fail "R1: timeout must be a number, got '$(rfield TIMEOUT)' — $R1"
        elif [ "$(rfield TIMEOUT)" != "$WANT_TIMEOUT" ]; then
            # The value is part of the contract, not a free parameter. InstructionsLoaded
            # runs on the session's critical path: the detail plan fixes it at 5s so a
            # stalled receipt write degrades to a fail-open miss instead of holding up
            # every turn, and "any number" would accept a 600s entry that turns this
            # audit hook into a hang. Too small is equally wrong — a 1s budget makes the
            # receipt writer flaky and the off-switch gate's absence evidence worthless.
            fail "R1: timeout must be exactly $WANT_TIMEOUT (detail plan S2-5), got '$(rfield TIMEOUT)'"
        else
            pass "R1: settings.json registers $EVENT -> instructions-loaded-audit.js (timeout=$(rfield TIMEOUT))"
        fi
        ;;
esac

# --- R2: the registration must not be hidden behind a tool matcher. InstructionsLoaded
# is not a tool event; a non-empty matcher would silently never match. ---
R2_MATCHER="$(rfield MATCHER)"
if [ -z "$R2_MATCHER" ]; then
    fail "R2: could not read the matcher list (R1 already failed: $R1)"
elif printf '%s' "$R2_MATCHER" | grep -q '"[^"]\+"'; then
    fail "R2: matcher must be empty for a non-tool event, got $R2_MATCHER"
else
    pass "R2: the $EVENT matcher group is unfiltered ($R2_MATCHER)"
fi

# --- R3: the installer must carry the key through the merge. The assembler writes to
# os.homedir(), so it is run against a redirected HOME — and only after a pre-flight
# proves node honours the redirection in this environment. Without that proof the
# assertion is skipped as a failure, never run against the real home directory. ---
FAKE_HOME="$BASE/home"
mkdir -p "$FAKE_HOME"
RESOLVED="$(HOME="$(node_path "$FAKE_HOME")" USERPROFILE="$(node_path "$FAKE_HOME")" \
    node -e "console.log(require('os').homedir())" 2>&1)"
NORM_FAKE="$(node_path "$FAKE_HOME")"
if [ "$(printf '%s' "$RESOLVED" | tr '\\' '/')" != "$(printf '%s' "$NORM_FAKE" | tr '\\' '/')" ]; then
    fail "R3: cannot redirect os.homedir() in this environment (got '$RESOLVED') — refusing to run the assembler against the real home"
else
    ASM_RC=0
    ( cd "$BASE" && HOME="$NORM_FAKE" USERPROFILE="$NORM_FAKE" node "$(node_path "$ASSEMBLER")" ) \
        >"$BASE/asm.log" 2>&1 || ASM_RC=$?
    OUT_SETTINGS="$FAKE_HOME/.claude/settings.json"
    if [ "$ASM_RC" != "0" ]; then
        fail "R3: assemble-settings.js exited $ASM_RC — $(head -3 "$BASE/asm.log" | tr '\n' ' ')"
    elif [ ! -f "$OUT_SETTINGS" ]; then
        fail "R3: assemble-settings.js wrote no settings.json under the redirected home"
    else
        # The count alone is not the contract. The merge is where a registration
        # degrades quietly: a matcher can be injected, the timeout dropped (the host
        # then applies its own default), the type rewritten, or the command rewritten
        # to an absolute path that is correct on the assembling machine only. Assert
        # the WHOLE post-assembly shape — the installed file is what actually runs, and
        # settings.json (checked by R1) is merely its input.
        R3="$(node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const ev = ((s.hooks || {})[process.argv[2]]) || [];
const groups = ev.filter((g) => g && Array.isArray(g.hooks)
  && g.hooks.some((h) => h && typeof h.command === 'string'
    && h.command.includes('instructions-loaded-audit.js')));
const entries = ev.flatMap((g) => (g && Array.isArray(g.hooks)) ? g.hooks : [])
  .filter((h) => h && typeof h.command === 'string'
    && h.command.includes('instructions-loaded-audit.js'));
if (entries.length !== 1) { console.log('COUNT=' + entries.length); process.exit(0); }
const h = entries[0];
const g = groups[0];
console.log([
  'COUNT=1',
  'TYPE=' + h.type,
  'CMD_EXACT=' + (h.command === process.argv[3] ? 'yes' : 'no'),
  'CMD_B64=' + Buffer.from(h.command, 'utf8').toString('base64'),
  'TIMEOUT=' + JSON.stringify(h.timeout),
  'MATCHER=' + JSON.stringify(g.matcher === undefined ? '<absent>' : g.matcher),
  'KEYS=' + Object.keys(h).sort().join(','),
].join(' '));
" "$(node_path "$OUT_SETTINGS")" "$EVENT" "$WANT_CMD" 2>&1)"
        a3() { printf '%s' "$R3" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }
        A3_MATCHER="$(a3 MATCHER)"
        if [ "$(a3 COUNT)" != "1" ]; then
            fail "R3: want exactly 1 $EVENT entry in the assembled settings, got '$R3'"
        elif [ "$(a3 TYPE)" != "command" ]; then
            fail "R3: the assembled entry has type '$(a3 TYPE)', want command — $R3"
        elif [ "$(a3 CMD_EXACT)" != "yes" ]; then
            fail "R3: the merge rewrote the command — want [$WANT_CMD], got [$(printf '%s' "$R3" | tr ' ' '\n' | grep '^CMD_B64=' | cut -d= -f2- | base64 -d 2>/dev/null)]"
        elif [ "$(a3 TIMEOUT)" != "$WANT_TIMEOUT" ]; then
            fail "R3: the merge lost or changed the timeout — want $WANT_TIMEOUT, got $(a3 TIMEOUT)"
        elif [ "$A3_MATCHER" != '""' ]; then
            fail "R3: the assembled matcher must stay the empty string for a non-tool event, got $A3_MATCHER"
        elif [ "$(a3 KEYS)" != "command,timeout,type" ]; then
            fail "R3: the assembled entry carries unexpected keys [$(a3 KEYS)], want exactly command,timeout,type"
        else
            pass "R3: the assembled settings carry exactly one $EVENT entry with the exact matcher/type/command/timeout"
        fi
    fi
fi

# --- R4: the command's script path must resolve to a file that exists in the repo.
# A registered-but-misspelled path is a dead hook that no behavioural test detects. ---
R4_CMD="$(rcmd)"
R4_REL="$(printf '%s' "$R4_CMD" | sed -n 's|.*AGENTS_CONFIG_DIR/\([^"]*\)".*|\1|p')"
if [ -z "$R4_REL" ]; then
    fail "R4: could not extract a \$AGENTS_CONFIG_DIR-relative script path from [$R4_CMD]"
elif [ -f "$AGENTS_DIR/$R4_REL" ]; then
    pass "R4: the registered command points at an existing file ($R4_REL)"
else
    fail "R4: the registered command points at a missing file ($R4_REL)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
