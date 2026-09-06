#!/usr/bin/env bash
# Tests: settings.json, hooks/lib/tool-command-text.js, install/gen-settings-allow.js, install/settings-allow-commands.txt
# Tags: capture-echo-guard, hook-registration, settings-json, static-check, scope:issue-specific, pwsh-not-required
# Section E — settings.json consistency (static/TL2). Mandatory integration coverage
# item #1/#2 of skills/_shared/test-design.md: a unit test of the hook cannot fail when
# the registration is missing, so the real settings.json is loaded here.
# E-1/E-2 correctly FAIL against pre-fix state; E-3/E-4 must PASS today.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
DRIVER="$(cd "$(dirname "$0")" && pwd)/settings-driver.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# The expected matcher is DERIVED from the SSOT module, never hard-coded here, so a
# future tool-name addition surfaces as a registration failure rather than drifting.
EXPECTED="$(node "$DRIVER" --expected-matcher)"

assert_eq "E-1a-block-capture-echo-matcher" "$EXPECTED" \
    "$(node "$DRIVER" --matcher-for "block-capture-echo.js")"
assert_eq "E-1b-block-capture-echo-timeout" "5" \
    "$(node "$DRIVER" --timeout-for "block-capture-echo.js")"

assert_eq "E-2a-auto-approve-covers-command-tools" "yes" \
    "$(node "$DRIVER" --covers-command-tools "preuse-auto-approve.js")"
# The pre-existing Monitor/EnterWorktree coverage must survive the matcher extension.
auto_matcher="$(node "$DRIVER" --matcher-for "preuse-auto-approve.js")"
has_tok() { case "|$1|" in *"|$2|"*) printf 'yes' ;; *) printf 'no' ;; esac; }
assert_eq "E-2b-auto-approve-keeps-monitor"       "yes" "$(has_tok "$auto_matcher" "Monitor")"
assert_eq "E-2c-auto-approve-keeps-enterworktree" "yes" "$(has_tok "$auto_matcher" "EnterWorktree")"

# E-3: permissions.allow is untouched by this work (no drift against the SSOT list).
gen_rc=0
node "$AGENTS_DIR/install/gen-settings-allow.js" --check >/dev/null 2>&1 || gen_rc=$?
assert_eq "E-3-gen-settings-allow-check-clean" "0" "$gen_rc"

# E-4: the SSOT file buildRemedy reads is present and non-empty.
ssot_state="missing"
if [ -s "$AGENTS_DIR/install/settings-allow-commands.txt" ]; then ssot_state="present"; fi
assert_eq "E-4-ssot-file-present" "present" "$ssot_state"

# E-5 (round 13, C9): real-hook-entry.js is what the TL3 fixtures build their project
# settings from. It is exercised HERE, at TL2, because TL3 is gated off by default —
# an extractor that only ever runs behind RUN_TL3 is an untested test dependency.
ENTRY_DRV="$(cd "$(dirname "$0")" && pwd)/real-hook-entry.js"
for hook in block-capture-echo.js preuse-auto-approve.js; do
    assert_eq "E-5a-matcher-agrees-with-settings-driver-[$hook]" \
        "$(node "$DRIVER" --matcher-for "$hook")" "$(node "$ENTRY_DRV" --matcher "$hook")"
    assert_eq "E-5b-timeout-agrees-with-settings-driver-[$hook]" \
        "$(node "$DRIVER" --timeout-for "$hook")" "$(node "$ENTRY_DRV" --timeout "$hook")"

    emitted="$(node "$ENTRY_DRV" --emit "$hook")"
    shape="$(printf '%s' "$emitted" | node -e '
let s = ""; process.stdin.on("data", (d) => { s += d; }).on("end", () => {
  let j; try { j = JSON.parse(s); } catch (e) { return console.log("NOT_JSON"); }
  const es = ((j.hooks || {}).PreToolUse) || [];
  const hs = es.length === 1 ? es[0].hooks || [] : [];
  const cmd = hs.length === 1 ? String(hs[0].command) : "";
  const placeholder = /\$\{?(CLAUDE_PROJECT_DIR|AGENTS_CONFIG_DIR)\}?|(^|[\s"])~\//.test(cmd);
  console.log([es.length, hs.length, placeholder ? "unresolved" : "resolved",
               cmd.indexOf(process.argv[1]) !== -1 ? "names-hook" : "hook-MISSING"].join("/"));
});' "$hook")"
    assert_eq "E-5c-emitted-fixture-is-one-resolved-entry-[$hook]" "1/1/resolved/names-hook" "$shape"
done

# Non-vacuity: the extractor must be able to say NO.
assert_eq "E-5d-unregistered-hook-is-reported" "NOT_REGISTERED" \
    "$(node "$ENTRY_DRV" --emit "no-such-hook-xyz.js")"

echo ""
echo "Section E: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
