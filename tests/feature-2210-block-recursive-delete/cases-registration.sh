# tests/feature-2210-block-recursive-delete/cases-registration.sh
# Tests: settings.json, hooks/block-recursive-delete.js
# Tags: scope:issue-specific, recursive-delete, hook-registration, settings-json, static, TL2, pwsh-not-required
#
# Static assertions on the real settings.json (test-design.md "Mandatory
# integration or E2E coverage" 1/2) — a judgment-function unit test still
# passes even if the hook is never registered or the deny globs remain.
# TL3 gap: static JSON inspection only, never a live PreToolUse event.

# settings_probe <probe-name> — one word per question about settings.json.
# C3: isRealEntry() below requires an exact match, not a basename substring.
settings_probe() {
    run_with_timeout 30 node -e '
const fs = require("fs");
const probe = process.argv[2];
let s;
try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
catch (e) { process.stdout.write("SETTINGS-UNREADABLE:" + e.message); process.exit(0); }

const EXPECTED_COMMAND = "node \"$AGENTS_CONFIG_DIR/hooks/block-recursive-delete.js\"";
function isRealEntry(h) {
  return !!h && h.type === "command" && h.command === EXPECTED_COMMAND;
}

const pre = (s.hooks && s.hooks.PreToolUse) || [];
const entries = pre.filter((e) => ((e && e.hooks) || []).some(isRealEntry));
const realHook = entries.length ? (entries[0].hooks || []).find(isRealEntry) : null;
// Finding 8: sibling PreToolUse hooks must survive the settings.json edits
// made for this issue, untouched -- same isRealEntry-shaped exact match.
function siblingSurvives(name) {
  const cmd = "node \"$AGENTS_CONFIG_DIR/hooks/" + name + "\"";
  return pre.some((e) => ((e && e.hooks) || []).some((h) => h && h.type === "command" && h.command === cmd));
}
// round-4 C6: entries.length only counts matcher ENTRIES -- a duplicate hook
// OBJECT inside one matcher .hooks array would still read entries.length===1.
const hookObjectCount = pre.reduce((sum, e) => sum + ((e && e.hooks) || []).filter(isRealEntry).length, 0);

const deny = (s.permissions && s.permissions.deny) || [];
const allow = (s.permissions && s.permissions.allow) || [];
const RETIRED = [
  "Bash(*Remove-Item*-Recurse*-Force*)",
  "Bash(*Remove-Item*-Force*-Recurse*)",
  "Bash(*rm -rf *)",
  "Bash(*rm -fr *)",
];
// detail.md Out of scope: the find-family deny 7 guard a DIFFERENT class
// (find-driven arbitrary command execution, not deletion) and must survive
// this issue deny edits untouched -- regression guard against accidentally
// removing them alongside the retired recursive-delete globs.
const FIND_DENY = [
  "Bash(*find *-exec *)",
  "Bash(*find *-execdir *)",
  "Bash(*find *-ok *)",
  "Bash(*find *-okdir *)",
  "Bash(*find *-delete*)",
  "Bash(*find *-fprint*)",
  "Bash(*find *-fls*)",
];

const decoyEntry = { type: "command", command: "echo block-recursive-delete.js" };
const realEntryShape = { type: "command", command: EXPECTED_COMMAND };

const out = {
  registered: entries.length === 1 ? "yes" : "count=" + entries.length,
  matcher: entries.length ? String(entries[0].matcher) : "NONE",
  timeout: realHook ? String(realHook.timeout) : "NONE",
  command: realHook ? String(realHook.command) : "NONE",
  "matcher-rejects-decoy": isRealEntry(decoyEntry) ? "BUG-accepted" : "yes",
  "matcher-accepts-real": isRealEntry(realEntryShape) ? "yes" : "BUG-rejected",
  "retired-deny": RETIRED.filter((r) => deny.indexOf(r) !== -1).join("|") || "none-left",
  "find-deny-survives": FIND_DENY.filter((r) => deny.indexOf(r) === -1).join("|") || "all-present",
  "cleanup-allow": allow.indexOf("Bash(node * hooks/cleanup-orphan-dir.js *)") !== -1 ? "yes" : "no",
  "cleanup-allow-backslash": allow.indexOf("Bash(node *\\hooks\\cleanup-orphan-dir.js *)") !== -1 ? "yes" : "no",
  "hook-object-count": String(hookObjectCount),
  "sibling-scan-outbound": siblingSurvives("scan-outbound.js") ? "yes" : "no",
  "sibling-enforce-system-ops": siblingSurvives("enforce-system-ops.js") ? "yes" : "no",
  "sibling-block-subagent-sentinels": siblingSurvives("block-subagent-sentinels.js") ? "yes" : "no",
};
process.stdout.write(Object.prototype.hasOwnProperty.call(out, probe) ? out[probe] : "UNKNOWN-PROBE");
' -- "$SETTINGS" "$1" 2>/dev/null
}

assert_probe() {
    local desc="$1" probe="$2" want="$3" got
    got="$(settings_probe "$probe")"
    if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc — expected '$want', got '$got'"; fi
}

run_registration_cases() {
    echo ""
    echo "=== settings.json registration (stage 1) ==="

    assert_probe "PreToolUse registers hooks/block-recursive-delete.js exactly once" \
        registered yes
    assert_probe "the entry matches all three command tools" \
        matcher "Bash|runInTerminal|runCommands"
    assert_probe "the entry declares a timeout (5s, as its enforce-system-ops sibling)" \
        timeout 5
    assert_probe "the entry's command field is the exact sanctioned invocation string" \
        command 'node "$AGENTS_CONFIG_DIR/hooks/block-recursive-delete.js"'

    echo ""
    echo "=== settings.json registration matcher — meta-test (C3) ==="

    # Proves the structural matcher itself, not just its result on the real
    # file: a mention-only decoy command must be rejected, the real shape
    # accepted. Without this, a substring check like the pre-fix version
    # (`command.indexOf("block-recursive-delete.js") !== -1`) would silently
    # pass `"command": "echo block-recursive-delete.js"`.
    assert_probe "matcher rejects a decoy command that merely names the script" \
        matcher-rejects-decoy yes
    assert_probe "matcher accepts the real command shape" \
        matcher-accepts-real yes
    # round-4 C6: entries.length===1 only proves ONE matcher entry exists — it
    # would stay 1 even if the SAME hook object appeared twice inside that
    # entry's .hooks array. This counts hook OBJECTS across all entries.
    assert_probe "the hook object is registered exactly once, not duplicated within its matcher entry (round-4 C6)" \
        hook-object-count "1"

    echo ""
    echo "=== settings.json deny retirement (stage 2) ==="

    # The four substring globs the hook replaces. Leaving one behind keeps the
    # false-positive class #2210 exists to remove.
    assert_probe "all four recursive-delete deny globs are gone" \
        retired-deny none-left

    echo ""
    echo "=== settings.json find-family deny survives untouched (detail.md Out of scope) ==="

    # find's -exec/-execdir/-ok/-okdir/-delete/-fprint/-fls deny 7 guard a
    # separate class (find-driven arbitrary command execution) and are not
    # part of this issue's edits — regression guard against them being
    # accidentally removed alongside the retired recursive-delete globs.
    assert_probe "all seven find-family deny globs survive stage 2's deny edits" \
        find-deny-survives all-present

    echo ""
    echo "=== settings.json sibling PreToolUse hooks survive untouched (finding 8) ==="

    assert_probe "hooks/scan-outbound.js entry still present/unmodified" \
        sibling-scan-outbound yes
    assert_probe "hooks/enforce-system-ops.js entry still present/unmodified" \
        sibling-enforce-system-ops yes
    assert_probe "hooks/block-subagent-sentinels.js entry still present/unmodified" \
        sibling-block-subagent-sentinels yes

    echo ""
    echo "=== settings.json untouched neighbours ==="

    assert_probe "permissions.allow still permits the sanctioned cleanup route" \
        cleanup-allow yes
    # MEDIUM: the backslash-path variant is a separate literal glob string
    # (Windows-form paths do not glob-match the forward-slash variant) — both
    # forms must survive this issue's settings.json edits untouched.
    assert_probe "permissions.allow also permits the backslash-path form (Windows)" \
        cleanup-allow-backslash yes
}
