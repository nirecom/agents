# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle/process-identity.js, install/codegraph-mcp.js, agents/supervisor.md, agents/supervisor-audit.md
# Tags: codegraph, wiring, static, negative-guard, table-driven, TL2, pwsh-not-required, scope:issue-specific
# W2 — negative guards. Each row names an ANCHOR file that must exist before the
# absence means anything: "string X is absent from file Y" is trivially true when
# Y does not exist, and a guard that passes by vacancy is a false green.

echo "=== W2: permanent negative guards (rejected shortcuts) ==="

while IFS='|' read -r name rel needle why; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_absent "$name" "$(trim "$rel")" "$(trim "$needle")" "$(trim "$why")"
done <<'W2_TABLE'
# C2 — daemon identity must be argv-exact; a substring test against the command line
# also matches <root>-old and <root>/sub, killing a neighbouring worktree's daemon.
W2-01 | bin/codegraph-lifecycle/process-identity.js | .includes("--path | Substring matching against the command line IS the C2 misfire; compare the element after an argv element equal to --path.
# C1 — never hand control to codegraph's own installer: it writes hooks.UserPromptSubmit
# and rewrites ~/.claude/CLAUDE.md, which on this machine is a symlink into the repo.
W2-02 | install/codegraph-mcp.js | codegraph install    | Calling the upstream installer breaks two Accepted Tradeoffs; state the prohibition without the literal command spelling.
W2-03 | install/codegraph-mcp.js | codegraph uninstall  | Upstream uninstall defaults to --target all and strips a marked section out of ~/.claude/CLAUDE.md.
W2-04 | install/codegraph-mcp.js | --target claude      | The claude target flag exists only on the upstream installer this design refuses to call.
# ST-8 — the two supervisor agents were triaged OPTIONAL and deliberately NOT adopted.
W2-05 | agents/supervisor.md       | mcp__codegraph | Session auditing does not need code structure; adding it here silently reverses a recorded triage decision.
W2-06 | agents/supervisor-audit.md | mcp__codegraph | Symmetric member of the same non-adoption decision as agents/supervisor.md.
W2_TABLE

# W3 — install/ tree scan. Wider than W2's per-file rows on purpose: the C1
# prohibition binds every file under install/, present and future, not only the
# helper that exists today.
echo "=== W3: no file under install/ reaches for the upstream installer (C1) ==="

W3_ANCHORS_OK=1
for anchor in install/codegraph-mcp.js install/win/codegraph.ps1 install/linux/codegraph.sh; do
    if [ ! -f "$AGENTS_DIR/$anchor" ]; then
        W3_ANCHORS_OK=0
        fail "W3-00: anchor $anchor is absent" "until the CodeGraph installer files exist, a clean install/ tree proves nothing"
    fi
done

while IFS='|' read -r name needle; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    needle="$(trim "$needle")"
    hits="$(grep -rIlF -e "$needle" "$AGENTS_DIR/install" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        fail "$name: '$needle' appears under install/" "$(printf '%s' "$hits" | tr '\n' ' ')"
    elif [ "$W3_ANCHORS_OK" -eq 1 ]; then
        pass "$name: no file under install/ contains '$needle'"
    else
        fail "$name: install/ is clean of '$needle' only because the CodeGraph installer files do not exist yet"
    fi
done <<'W3_TABLE'
W3-01 | codegraph install
W3-02 | codegraph uninstall
W3-03 | --target claude
W3_TABLE
