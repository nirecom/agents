#!/usr/bin/env bash
# Part of tests/hooks/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
# Tests: hooks/enforce-system-ops.js, hooks/lib/system-ops-categories.js, settings.json
# Tags: system-ops, mutation-probe, classifier, hook-registration, security, scope:common, pwsh-not-required
# Section M - mutation evidence: each probe neuters exactly one category regex in
# a COPY of the classifier and asserts the matching row flips BLOCK -> ALLOW while
# a sibling category stays BLOCK, so a probe cannot pass by breaking the whole
# file. Section R - registration: the PreToolUse matcher the host evaluates
# before any hook code runs, asserted against settings.json.
mutate_hook() {
    # mutate_hook <literal-regex-fragment> -> path to a mutated copy
    local fragment="$1" dest="$TMP/mutant.js" libdest="$TMP/mutant-lib.js"
    cp "$HOOK" "$dest"
    cp "$SCRIPT_CHECKOUT_ROOT/hooks/lib/system-ops-categories.js" "$libdest"
    # Replace the target regex fragment with a never-match group. The category
    # regexes live in hooks/lib/system-ops-categories.js and the interpreter-body
    # regex in the hook itself, so the fragment is sought in BOTH copies. Both
    # copies sit outside hooks/, so the hook copy's `require("./lib/...")`
    # specifiers are re-pointed — at the mutant lib for the category module, at
    # the real hooks directory for the rest — otherwise the mutant dies on
    # MODULE_NOT_FOUND and every probe would "pass" for the wrong reason.
    node -e '
const fs = require("fs");
const [dest, libDest, frag, hooksDir] = process.argv.slice(1);
let src = fs.readFileSync(dest, "utf8");
let lib = fs.readFileSync(libDest, "utf8");
const neuter = (s) => {
  const i = s.indexOf(frag);
  return i === -1 ? null : s.slice(0, i) + "(?!x)x" + s.slice(i + frag.length);
};
const mutSrc = neuter(src);
const mutLib = mutSrc === null ? neuter(lib) : null;
if (mutSrc === null && mutLib === null) { process.stderr.write("fragment-not-found"); process.exit(3); }
if (mutSrc !== null) { src = mutSrc; } else { lib = mutLib; }
src = src.split("\"./lib/system-ops-categories\"").join(JSON.stringify(libDest));
src = src.split("\"./lib/").join("\"" + hooksDir + "/lib/");
fs.writeFileSync(dest, src);
fs.writeFileSync(libDest, lib);
' "$(topath "$dest")" "$(topath "$libdest")" "$fragment" "$(topath "$SCRIPT_CHECKOUT_ROOT/hooks")" 2>"$TMP/mut-err.txt" || return 1
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

# The interpreter-body extractor is the other single point of failure: stubbing
# inlineBodiesOf to return nothing must let a wrapped blocked command through
# while the unwrapped form still blocks. That distinguishes "the W table works"
# from "the W table is redundant with the C table".
probe_inline_body_stub
}

probe_inline_body_stub() {
    local dest="$TMP/mutant-ib.js" stub="$TMP/stub-ib.js" got_killed got_survivor saved
    cp "$HOOK" "$dest"
    node -e '
const fs = require("fs");
const [dest, stub, hooksDir] = process.argv.slice(1);
fs.writeFileSync(stub, "module.exports = Object.assign({}, require(" +
  JSON.stringify(hooksDir + "/lib/interpreter-inline-body") +
  "), { inlineBodiesOf: () => ({ bodies: [], unparsedLines: [] }) });\n");
let src = fs.readFileSync(dest, "utf8");
src = src.replace(/["\x27]\.\/lib\/interpreter-inline-body(?:\.js)?["\x27]/g, JSON.stringify(stub));
src = src.split("\"./lib/").join("\"" + hooksDir + "/lib/");
fs.writeFileSync(dest, src);
' "$(topath "$dest")" "$(topath "$stub")" "$(topath "$SCRIPT_CHECKOUT_ROOT/hooks")" 2>"$TMP/mut-err.txt" || {
        fail "M inlineBodiesOf — could not build mutant: $(cat "$TMP/mut-err.txt" 2>/dev/null)"
        return
    }
    saved="$HOOK"
    HOOK="$dest"
    got_killed="$(run_cmd "bash -c 'winget install jq'")"
    got_survivor="$(run_cmd 'winget install jq')"
    HOOK="$saved"
    if [ "$got_killed" = "ALLOW" ] && [ "$got_survivor" = "BLOCK" ]; then
        pass "M inlineBodiesOf — stubbing the extractor flips only the wrapped row (killed=$got_killed sibling=$got_survivor)"
    else
        fail "M inlineBodiesOf — want killed=ALLOW sibling=BLOCK, got killed=$got_killed sibling=$got_survivor"
    fi
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
' "$(topath "$SETTINGS")" "$(topath "$SCRIPT_CHECKOUT_ROOT/hooks/lib/tool-command-text.js")" 2>/dev/null)
    assert_eq "R1 settings.json fires enforce-system-ops.js for every command tool" \
        '{"missing":[],"count":3}' "$reg"
fi
}
