#!/usr/bin/env bash
# Part of tests/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
# Sections M and R - the two sections that answer "would the tables above
# NOTICE a regression?" (M, by neutering one rule at a time in a copy of the
# hook) and "can the tables above be reached at all in production?" (R, by
# asserting the PreToolUse registration the host evaluates before any hook code).

# ===========================================================================
# Section M - mutation evidence. Table rows only prove the current code answers
# the way the table says; they do not prove the table would NOTICE the rule
# being removed. Each probe neuters exactly one category regex in a COPY of the
# hook and asserts the matching row flips BLOCK -> ALLOW while a sibling
# category stays BLOCK (so the probe cannot pass by breaking the whole file).
# ===========================================================================
mutate_hook() {
    # mutate_hook <literal-regex-fragment> -> path to a mutated copy
    local fragment="$1" dest="$TMP/mutant.js"
    cp "$HOOK" "$dest"
    # Replace the target regex fragment with a never-match group. The copy lives
    # outside hooks/, so its `require("./lib/...")` specifiers are re-pointed at
    # the real hooks directory — otherwise the mutant dies on MODULE_NOT_FOUND
    # and every probe would "pass" for the wrong reason.
    node -e '
const fs = require("fs");
const [dest, frag, hooksDir] = process.argv.slice(1);
let src = fs.readFileSync(dest, "utf8");
const i = src.indexOf(frag);
if (i === -1) { process.stderr.write("fragment-not-found"); process.exit(3); }
src = src.slice(0, i) + "(?!x)x" + src.slice(i + frag.length);
src = src.split("\"./lib/").join("\"" + hooksDir + "/lib/");
fs.writeFileSync(dest, src);
' "$(topath "$dest")" "$fragment" "$(topath "$AGENTS_DIR/hooks")" 2>"$TMP/mut-err.txt" || return 1
    printf '%s' "$dest"
}

probe_mutation() {
    # probe_mutation <name> <fragment> <killed-cmd> <survivor-cmd>
    local name="$1" fragment="$2" killed="$3" survivor="$4" mutant saved
    mutant="$(mutate_hook "$fragment")" || {
        fail "M $name — could not build mutant: $(cat "$TMP/mut-err.txt" 2>/dev/null)"
        return
    }
    saved="$HOOK"
    HOOK="$mutant"
    local got_killed got_survivor
    got_killed="$(run_cmd "$killed")"
    got_survivor="$(run_cmd "$survivor")"
    HOOK="$saved"
    if [ "$got_killed" = "ALLOW" ] && [ "$got_survivor" = "BLOCK" ]; then
        pass "M $name — neutering the rule flips only its own row (killed=$got_killed sibling=$got_survivor)"
    else
        fail "M $name — want killed=ALLOW sibling=BLOCK, got killed=$got_killed sibling=$got_survivor"
    fi
}

run_M_mutation() {
probe_mutation "A-winget"    'winget\s+(?:install|uninstall|upgrade)' 'winget install jq'   'apt install jq'
probe_mutation "B-shutdown"  'shutdown(?:\.exe)?\s+[/-][rshHP]'       'shutdown -h now'     'reboot'
probe_mutation "C-systemctl" 'systemctl\s+(?:stop|disable|mask)'      'systemctl stop nginx' 'Stop-Service Spooler'
probe_mutation "F-mkfs"      'mkfs(?:\.[a-z0-9]+)?\s'                 'mkfs.ext4 /dev/sdb1' 'diskpart'

# The interpreter-body extractor is the other single point of failure: neutering
# it must let a wrapped blocked command through while the unwrapped form still
# blocks. That distinguishes "the W table works" from "the W table is redundant
# with the C table".
probe_mutation "getInnerBodies" \
    '(?:^|[\s;|&])(?:bash|sh|zsh|pwsh|powershell(?:\.exe)?)\b[^|;&\n]*-c\s+' \
    "bash -c 'winget install jq'" \
    'winget install jq'
}

# ===========================================================================
# Section R - registration. Everything above is unreachable if settings.json
# does not fire this hook for the command tools: PreToolUse matching happens in
# the host, before any hook code runs. Asserted against the same SSOT the hook
# branches on (hooks/lib/tool-command-text.js COMMAND_TOOL_NAMES).
# ===========================================================================
run_R_registration() {
if [ ! -f "$SETTINGS" ]; then
    skip "R settings.json not found"
else
    reg=$(run_with_timeout 15 node -e '
const s = require(process.argv[1]);
const { COMMAND_TOOL_NAMES } = require(process.argv[2]);
const entries = (s.hooks && s.hooks.PreToolUse) || [];
const entry = entries.find((e) =>
  (e.hooks || []).some((h) => String(h.command || "").includes("enforce-system-ops.js")));
if (!entry) { process.stdout.write("NOT-REGISTERED"); process.exit(0); }
const listed = String(entry.matcher || "").split("|").map((x) => x.trim()).filter(Boolean);
const missing = COMMAND_TOOL_NAMES.filter((n) => listed.indexOf(n) === -1);
process.stdout.write(JSON.stringify({ missing, count: COMMAND_TOOL_NAMES.length }));
' "$(topath "$SETTINGS")" "$(topath "$AGENTS_DIR/hooks/lib/tool-command-text.js")" 2>/dev/null)
    assert_eq "R1 settings.json fires enforce-system-ops.js for every command tool" \
        '{"missing":[],"count":3}' "$reg"
fi
}
