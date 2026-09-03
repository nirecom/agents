# shellcheck shell=bash
# Tests: hooks/lib/spawn-shimmed-cli.js, bin/codegraph-lifecycle.js, install/codegraph-mcp.js
# Tags: codegraph, win32-shim, spawn, security, command-injection, wiring, unit, scope:issue-specific
# Sections A and W of tests/feature-2150-spawn-shimmed-cli.sh. A runs the module
# for real — argv fidelity and the planted-payload attack. W pins the wiring: a
# helper only both production callers actually go through can protect them.

run_A_attack_and_argv() {
# A-argv reads the decision without executing it; A-exec executes it and reads
# the argv the target itself recorded. Both carry `x&y` and `$(id)`: any layer
# that grew a shell would mangle or expand them, and `shell=undefined` pins that
# the option is never set (CVE-2024-27980 is escaped by NOT launching the batch
# file, not by asking cmd.exe nicely). A-posix is the non-win32 half — the
# helper must stay a transparent spawnSync there.
run_table A <<'TABLE'
A-argv  | node d1/codegraph-target.js :: --flag,a b,x&y,$(id) :: shell=undefined | argv  | trio | .COM;.EXE;.BAT;.CMD | d1 | codegraph
A-exec  | status=0 argv=--flag,a b,x&y,$(id)                                     | exec  | trio | .COM;.EXE;.BAT;.CMD | d1 | codegraph
A-posix | status=7                                                               | posix | trio | .COM;.EXE;.BAT;.CMD | d1 | codegraph
TABLE

# The C4 proof. bld_payload / bld_batpayload plant a shim that is a VALID npm
# batch shim and also carries `DEL` + `ECHO tampered-by-shell` against a
# protected marker. cmd.exe would destroy the marker; a text parser reads the
# target line and never runs the rest. Both extensions, since .bat and .cmd are
# separate allow-list entries. Single-row tables so LAST_CASE_DIR names the
# fixture whose marker is then read back.
_a_payload() {
    local name="$1" builder="$2"
    run_row A "$name" "status=0 argv=--flag,a b,x&y,\$(id)" exec "$builder" ".COM;.EXE;.BAT;.CMD" d1 codegraph
    if [ "${LAST_GOT#load-failed}" != "$LAST_GOT" ]; then
        fail "A $name — the marker survived only because the module never ran (no evidence)"
    else
        assert_eq "A $name — the planted shim body was never shell-executed" \
            "pristine" "$(cat "$LAST_CASE_DIR/__payload.txt" 2>/dev/null || echo "<destroyed-or-missing>")"
    fi
}
_a_payload A-payload-cmd payload
_a_payload A-payload-bat batpayload
}

run_W_wiring() {
# Static wiring. The A rows prove the helper is safe; these prove the two
# production callers cannot silently keep their own raw spawnSync alongside it —
# the "bypassed" half of C1. Counts, not presence: `spawnSync("codegraph"` must
# reach zero, and install/codegraph-mcp.js has TWO call sites (claudeCliPresent
# and runClaude), so CPR-ORTH is a number here, not a yes/no.
local life="$AGENTS_DIR/bin/codegraph-lifecycle.js"
local mcp="$AGENTS_DIR/install/codegraph-mcp.js"
assert_eq "W-1 codegraph-lifecycle.js requires the shared helper" "1" \
    "$(grep -c 'require(.*hooks/lib/spawn-shimmed-cli' "$life" 2>/dev/null || true)"
assert_eq "W-2 codegraph-mcp.js requires the shared helper" "1" \
    "$(grep -c 'require(.*hooks/lib/spawn-shimmed-cli' "$mcp" 2>/dev/null || true)"
assert_eq "W-3 the codegraph spawn goes through the helper" "1" \
    "$(grep -c 'spawnShimmedCli("codegraph"' "$life" 2>/dev/null || true)"
assert_eq "W-4 no raw spawnSync(\"codegraph\") remains" "0" \
    "$(grep -c 'spawnSync("codegraph"' "$life" 2>/dev/null || true)"
assert_eq "W-5 both claude spawns go through the helper" "2" \
    "$(grep -c 'spawnShimmedCli("claude"' "$mcp" 2>/dev/null || true)"
assert_eq "W-6 no raw spawnSync(\"claude\") remains" "0" \
    "$(grep -c 'spawnSync("claude"' "$mcp" 2>/dev/null || true)"
assert_eq "W-7 the module exports exactly one entry point" "spawnShimmedCli" \
    "$(node -e 'try{console.log(Object.keys(require(process.argv[1])).sort().join(","))}catch(e){console.log("load-failed")}' \
        "$ROOT_N/$MODULE_REL" 2>/dev/null || true)"
assert_eq "W-8 the module never opts into shell:true" "0" \
    "$(grep -cE '^[^/]*shell:[[:space:]]*true' "$AGENTS_DIR/$MODULE_REL" 2>/dev/null || true)"

# W-9 — Section O pins the value 60000 as the timeout that must survive the
# helper. If the caller ever changes STATUS_TIMEOUT_MS, that expectation goes
# stale silently; this row makes the drift a failure instead.
assert_eq "W-9 codegraph-lifecycle.js still bounds the binary at STATUS_TIMEOUT_MS = 60000" "1" \
    "$(grep -c 'STATUS_TIMEOUT_MS = 60000' "$life" 2>/dev/null || true)"

# W-10..W-13 — the docs half of the fix. The operator-facing verification step
# is part of the resolution contract: a runbook that still says "run
# `codegraph --version`" teaches the exact check that passes in PowerShell while
# spawnSync fails, which is the defect. Absence AND presence are both asserted:
# deleting the old row without adding the new one would satisfy only one.
local ops="$AGENTS_DIR/docs/ops/codegraph.md"
assert_eq "W-10 the bare shell-mediated \`codegraph --version\` check is gone from Verifying the setup" "0" \
    "$(grep -c '^| Binary | `codegraph --version` |' "$ops" 2>/dev/null || true)"
assert_eq "W-11 the docs verify through spawnShimmedCli instead" "1" \
    "$(grep -c "spawnShimmedCli('codegraph',\['--version'\]" "$ops" 2>/dev/null || true)"
assert_eq "W-12 the documented check judges on r.error, not on ENOENT alone" "0" \
    "$(grep -c "r.error.code === 'ENOENT'" "$ops" 2>/dev/null || true)"
assert_eq "W-13 the implementation map names the shim resolver" "1" \
    "$(grep -c 'hooks/lib/spawn-shimmed-cli.js)' "$ops" 2>/dev/null || true)"
}
