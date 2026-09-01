# shellcheck shell=bash
# Tests: install/codegraph-constants.txt, install/linux/codegraph.sh, install/win/codegraph.ps1, install/codegraph-mcp.js
# Tags: codegraph, installer, version-pin, ssot, supply-chain, static, TL2, pwsh-not-required, scope:issue-specific
# W12 (#2150 review) — the pinned version and the telemetry opt-out live in exactly
# one file. A floating `@colbymchenry/codegraph` installs whatever the registry
# serves at install time, and `npm install -g` without --ignore-scripts hands that
# tarball's postinstall a shell on the developer's machine. Both OS scripts must
# read the same constants file, so a bump cannot land on one platform only.

echo "=== W12: version SSOT and install hardening ==="

CONSTANTS_REL="install/codegraph-constants.txt"
CONSTANTS_ABS="$AGENTS_DIR/$CONSTANTS_REL"
W12_VERSION="$(sed -n 's/^CODEGRAPH_VERSION=//p' "$CONSTANTS_ABS" 2>/dev/null | head -1)"

# Without a real pinned value every "the literal is not repeated" row below would
# search for the empty string and pass for free.
case "$W12_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) pass "W12-01: $CONSTANTS_REL pins CODEGRAPH_VERSION to $W12_VERSION" ;;
    *) fail "W12-01: $CONSTANTS_REL does not pin an x.y.z CODEGRAPH_VERSION" "got '${W12_VERSION:-<none>}'" ;;
esac
assert_count_re "W12-02" "$CONSTANTS_REL" '^CODEGRAPH_VERSION=' 1 \
    "a second assignment makes the last one win, so the reviewed pin and the installed pin diverge"
assert_count_re "W12-03" "$CONSTANTS_REL" '^CODEGRAPH_TELEMETRY=' 1 \
    "the telemetry opt-out is read by both OS scripts and by codegraph-mcp.js; a duplicate hides which value ships"
assert_count_re "W12-04" "$CONSTANTS_REL" '^DO_NOT_TRACK=' 1 \
    "same contract as CODEGRAPH_TELEMETRY (CPR-ORTH)"

# The SSOT claim itself: no file under install/ or bin/ restates the version literal.
if [ -n "$W12_VERSION" ]; then
    W12_ECHOES="$(grep -rlF -e "$W12_VERSION" "$AGENTS_DIR/install" "$AGENTS_DIR/bin" 2>/dev/null \
        | grep -vF "codegraph-constants.txt" | sed "s|^$AGENTS_DIR/||" | tr '\n' ' ' || true)"
    assert_eq "W12-05: the version literal $W12_VERSION appears only in $CONSTANTS_REL" "" "$(trim "$W12_ECHOES")"
fi

# Both OS scripts: read the SSOT, pin the version, and refuse install scripts.
while IFS='|' read -r name rel needle; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_contains "$name" "$(trim "$rel")" "$(trim "$needle")"
done <<'W12_TABLE'
W12-06 | install/linux/codegraph.sh | install/codegraph-constants.txt
W12-07 | install/win/codegraph.ps1  | install\codegraph-constants.txt
W12-08 | install/linux/codegraph.sh | npm install -g --ignore-scripts "@colbymchenry/codegraph@$CODEGRAPH_VERSION"
W12-09 | install/win/codegraph.ps1  | npm install -g --ignore-scripts "@colbymchenry/codegraph@$CodegraphVersion"
W12-10 | install/codegraph-mcp.js   | codegraph-constants.txt
W12_TABLE

# Negative half (Pattern 1): the pre-fix spellings must be gone, not merely
# outnumbered by the fixed ones — a leftover unpinned line would still run.
while IFS='|' read -r name rel needle why; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_absent "$name" "$(trim "$rel")" "$(trim "$needle")" "$(trim "$why")"
done <<'W12_NEG_TABLE'
W12-11 | install/linux/codegraph.sh | npm install -g @colbymchenry/codegraph | an unpinned, script-running global install is the #2150 supply-chain finding
W12-12 | install/win/codegraph.ps1  | npm install -g @colbymchenry/codegraph | same finding on the Windows path (CPR-ORTH)
W12-13 | install/linux/codegraph.sh | npm install -g "@colbymchenry/codegraph" | quoting the bare name still floats the version and still runs install scripts
W12-14 | install/win/codegraph.ps1  | npm install -g "@colbymchenry/codegraph" | same finding on the Windows path (CPR-ORTH)
W12_NEG_TABLE

# Exactly one global install call per script: a second, unhardened one would run
# regardless of how correct the first is.
assert_count_re "W12-15" "install/linux/codegraph.sh" 'npm install -g' 1 \
    "a second global install line can carry different flags and silently defeat the hardened one"
assert_count_re "W12-16" "install/win/codegraph.ps1" 'npm install -g' 1 \
    "same contract on the Windows path (CPR-ORTH)"
