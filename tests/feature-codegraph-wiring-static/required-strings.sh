# shellcheck shell=bash
# Tests: .env.example, install.ps1, install.sh, install/win/codegraph.ps1, install/linux/codegraph.sh, install/codegraph-mcp.js, bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js, skills/worktree-start/SKILL.md, skills/worktree-end/SKILL.md, skills/worktree-end/scripts/cleanup-cascade.md, skills/sweep-worktrees/SKILL.md, settings.json
# Tags: codegraph, wiring, static, table-driven, TL2, pwsh-not-required, scope:issue-specific
# W1 — presence table. Every row is "this repo-relative file contains this exact
# text". A missing implementation file fails the row rather than skipping it: the
# whole point of this suite is to stay red until the wiring lands.

echo "=== W1: required wiring strings ==="

while IFS='|' read -r name rel needle; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_contains "$name" "$(trim "$rel")" "$(trim "$needle")"
done <<'W1_TABLE'
# flag definition (ST-1)
W1-01 | .env.example                        | CODEGRAPH=off
# installer entrypoints call the per-OS scripts (ST-5 / ST-6 — a CPR-ORTH pair)
W1-02 | install.ps1                         | install\win\codegraph.ps1
W1-03 | install.sh                          | install/linux/codegraph.sh
# both per-OS scripts read the flag AND own both transition directions (C3)
W1-04 | install/win/codegraph.ps1           | -IsOff CODEGRAPH off
W1-05 | install/win/codegraph.ps1           | codegraph-mcp.js" register
W1-06 | install/win/codegraph.ps1           | codegraph-mcp.js" unregister
W1-07 | install/linux/codegraph.sh          | --is-off CODEGRAPH off
W1-08 | install/linux/codegraph.sh          | codegraph-mcp.js" register
W1-09 | install/linux/codegraph.sh          | codegraph-mcp.js" unregister
# the MCP helper spells the claude-cli argv, never codegraph's own installer (C1).
# The argv is now assembled from SERVER_NAME/SERVER_ARGS plus the telemetry --env
# flags, so the rows pin the assembly and the constants it draws on (#2150 review).
W1-10 | install/codegraph-mcp.js            | ["mcp", "add", SERVER_NAME, "--scope", "user"]
W1-11 | install/codegraph-mcp.js            | ["mcp", "remove", SERVER_NAME, "-s", "user"]
W1-10b| install/codegraph-mcp.js            | .concat(["--", SERVER_COMMAND])
W1-10c| install/codegraph-mcp.js            | ["--env", key + "=" + wantedEnv[key]]
W1-10d| install/codegraph-mcp.js            | const SERVER_ARGS = ["serve", "--mcp"];
W1-10e| install/codegraph-mcp.js            | const TELEMETRY_KEYS = ["CODEGRAPH_TELEMETRY", "DO_NOT_TRACK"];
# the steady-state repair verb must stay `index`; `init` alone does not rebuild (C5)
W1-12 | bin/codegraph-lifecycle.js          | ["init", "-y"
W1-13 | bin/codegraph-lifecycle.js          | ["index", "-q"
# index health is decided from the schema, not from the SQLite magic bytes alone (C6)
W1-14 | bin/codegraph-lifecycle/index-health.js | project_metadata
W1-15 | bin/codegraph-lifecycle/index-health.js | schema_versions
W1-16 | bin/codegraph-lifecycle/index-health.js | index_state
W1-17 | bin/codegraph-lifecycle/index-health.js | nodes
# worktree lifecycle call sites (ST-12 / ST-13)
W1-18 | skills/worktree-start/SKILL.md       | WS-7a
W1-19 | skills/worktree-start/SKILL.md       | codegraph-lifecycle.js
W1-20 | skills/worktree-end/scripts/cleanup-cascade.md | ## WE-14c
W1-21 | skills/worktree-end/scripts/cleanup-cascade.md | codegraph-lifecycle.js
# the one tool the agents deliberately expose is pre-approved (ST-10)
W1-22 | settings.json                        | mcp__codegraph__codegraph_explore
# the two removal-path skill documents. worktree-end/SKILL.md carries the ST-13
# discovery pointer (the procedure itself stays in cleanup-cascade.md); the
# sweeper SKILL.md carries the ST-15 rule that records the same obligation for
# the third deletion path. Both are MUST rows of the plan's Files to modify table.
W1-23 | skills/worktree-end/SKILL.md         | WE-14c
W1-24 | skills/worktree-end/SKILL.md         | CodeGraph index lock
W1-25 | skills/sweep-worktrees/SKILL.md      | CodeGraph index lock
W1-26 | skills/sweep-worktrees/SKILL.md      | never killed
W1_TABLE
