# shellcheck shell=bash
# Tests: install/codegraph-constants.txt, install/linux/codegraph.sh, install/win/codegraph.ps1, install/codegraph-mcp.js, hooks/lib/codegraph-boundary.js
# Tags: codegraph, installer, install-hardening, supply-chain, static, TL2, pwsh-not-required, scope:issue-specific
# W12 (#2150 review, #2254 pin abolition) — both OS scripts install @latest with
# --ignore-scripts (no upstream postinstall shell), exactly once, and the telemetry
# env pair lives in one constants file. #2254 removed the version pin: no
# CODEGRAPH_VERSION, no verifyPinnedCliVersion, no "already installed" short-circuit.

echo "=== W12: install hardening (no version pin) ==="

CONSTANTS_REL="install/codegraph-constants.txt"

assert_count_re "W12-03" "$CONSTANTS_REL" '^CODEGRAPH_TELEMETRY=' 1 \
    "the telemetry opt-out is read by both OS scripts and by codegraph-mcp.js; a duplicate hides which value ships"
assert_count_re "W12-04" "$CONSTANTS_REL" '^DO_NOT_TRACK=' 1 \
    "same contract as CODEGRAPH_TELEMETRY (CPR-ORTH)"

# Both OS scripts install the latest release and refuse install scripts.
while IFS='|' read -r name rel needle; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_contains "$name" "$(trim "$rel")" "$(trim "$needle")"
done <<'W12_TABLE'
W12-08 | install/linux/codegraph.sh | npm install -g --ignore-scripts "@colbymchenry/codegraph@latest"
W12-09 | install/win/codegraph.ps1  | npm install -g --ignore-scripts "@colbymchenry/codegraph@latest"
W12-10 | hooks/lib/codegraph-boundary.js | codegraph-constants.txt
W12_TABLE

# Negative half (Pattern 1): the pre-fix spellings must be gone, not merely
# outnumbered by the fixed ones — a leftover unhardened line would still run.
while IFS='|' read -r name rel needle why; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_absent "$name" "$(trim "$rel")" "$(trim "$needle")" "$(trim "$why")"
done <<'W12_NEG_TABLE'
W12-11 | install/linux/codegraph.sh | npm install -g @colbymchenry/codegraph | a global install without --ignore-scripts hands the tarball's postinstall a shell (#2150 supply-chain finding)
W12-12 | install/win/codegraph.ps1  | npm install -g @colbymchenry/codegraph | same finding on the Windows path (CPR-ORTH)
W12-13 | install/linux/codegraph.sh | npm install -g "@colbymchenry/codegraph" | quoting the bare name still runs install scripts
W12-14 | install/win/codegraph.ps1  | npm install -g "@colbymchenry/codegraph" | same finding on the Windows path (CPR-ORTH)
W12-17 | install/linux/codegraph.sh | export CODEGRAPH_TELEMETRY | codegraph.sh runs as its own subprocess, so assigning the pair to its own env leaks it into every child it spawns (npm/claude/codegraph stub calls)
W12-18 | install/linux/codegraph.sh | export DO_NOT_TRACK | same leak risk as W12-17 for the paired var (CPR-ORTH)
W12-19 | install/win/codegraph.ps1  | $env:CODEGRAPH_TELEMETRY | codegraph.ps1 is dot-sourced in-process by install.ps1, so this assignment would outlive the script and leak into every command the caller's shell runs next, including `claude`
W12-20 | install/win/codegraph.ps1  | $env:DO_NOT_TRACK | same leak risk as W12-19; DO_NOT_TRACK is the var that makes claude's Remote Control refuse to start (CPR-ORTH)
W12-21 | install/linux/codegraph.sh | CodeGraph is already installed | #2254: skipping npm when a binary exists freezes the CLI at whatever version first landed
W12-22 | install/win/codegraph.ps1  | CodeGraph is already installed | same freeze on the Windows path (CPR-ORTH)
W12_NEG_TABLE

# #2254 pin abolition, repo-wide: a surviving pin variable or version gate anywhere
# in the shipped code would reintroduce the frozen/mismatch behaviour.
W12_PIN_HITS="$(grep -rlF -e "CODEGRAPH_VERSION" "$AGENTS_DIR/install" "$AGENTS_DIR/hooks" "$AGENTS_DIR/bin" 2>/dev/null \
    | sed "s|^$AGENTS_DIR/||" | tr '\n' ' ' || true)"
assert_eq "W12-23: CODEGRAPH_VERSION appears nowhere under install/, hooks/, bin/" "" "$(trim "$W12_PIN_HITS")"
W12_GATE_HITS="$(grep -rlF -e "verifyPinnedCliVersion" "$AGENTS_DIR/install" "$AGENTS_DIR/hooks" "$AGENTS_DIR/bin" 2>/dev/null \
    | sed "s|^$AGENTS_DIR/||" | tr '\n' ' ' || true)"
assert_eq "W12-24: verifyPinnedCliVersion appears nowhere under install/, hooks/, bin/" "" "$(trim "$W12_GATE_HITS")"

# Exactly one global install call per script: a second, unhardened one would run
# regardless of how correct the first is.
assert_count_re "W12-15" "install/linux/codegraph.sh" 'npm install -g' 1 \
    "a second global install line can carry different flags and silently defeat the hardened one"
assert_count_re "W12-16" "install/win/codegraph.ps1" 'npm install -g' 1 \
    "same contract on the Windows path (CPR-ORTH)"
