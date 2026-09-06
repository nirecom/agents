# shellcheck shell=bash
# Tests: .env.example, install.ps1, install.sh, install/win/codegraph.ps1, install/linux/codegraph.sh, install/codegraph-mcp.js, bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js, hooks/lib/codegraph-boundary.js, hooks/codegraph-context-inject.js, skills/worktree-start/SKILL.md, skills/worktree-end/SKILL.md, skills/worktree-end/scripts/cleanup-cascade.md, skills/sweep-worktrees/SKILL.md, settings.json
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
# the telemetry keys and their read-side move into the shared boundary module (C1)
W1-10e| hooks/lib/codegraph-boundary.js     | const TELEMETRY_KEYS = ["CODEGRAPH_TELEMETRY", "DO_NOT_TRACK"];
# the fallback pair is a privacy-side floor for an unreadable constants file, not a
# copy of the SSOT; it must not flip when C3 inverts the shipped defaults (R7)
W1-10f| hooks/lib/codegraph-boundary.js     | CODEGRAPH_TELEMETRY: "0", DO_NOT_TRACK: "1"
# the MCP registration ownership marker also lives in the boundary module (C2)
W1-10g| hooks/lib/codegraph-boundary.js     | AGENTS_CODEGRAPH_MCP_OWNER
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
# runInit's re-sync note must stay bound to a real daemon replacement (S4-1/S4-4)
W1-27 | bin/codegraph-lifecycle.js          | only once a new daemon serves this index
# the prompt-hook scope gate lives in the boundary module and the hook must call it,
# not merely define-and-ignore it (S5-9)
W1-28 | hooks/lib/codegraph-boundary.js     | promptHookScopeAllows
W1-29 | hooks/codegraph-context-inject.js   | promptHookScopeAllows
# cwd normalization is taken from the existing shared helper, not a private copy (CPR-SSOT)
W1-29b| hooks/lib/codegraph-boundary.js     | require("./path-normalize")
# the telemetry-reset report text and its output stay owned by the installer (S5-5)
W1-29c| install/codegraph-mcp.js            | RESET_NOTICE
# CLI pin verification lives in the boundary module and the installer calls it (S5-13)
W1-30 | hooks/lib/codegraph-boundary.js     | verifyPinnedCliVersion
W1-31 | install/codegraph-mcp.js            | verifyPinnedCliVersion
W1_TABLE

# W1-10f behavioral: prove the fallback pair is actually RETURNED when
# install/codegraph-constants.txt is unreadable/corrupted, not merely that the
# literal string appears somewhere in codegraph-boundary.js's source text.
# Mirrors make_constants_tree/constants_body from
# tests/feature-codegraph-bootstrap/fixtures.sh: hooks/lib/codegraph-boundary.js
# resolves the constants file relative to itself, so each variant gets its own
# copied hooks/lib + install tree (a shared lib dir would make every tree read
# the SAME constants file and collapse the "unreadable constants" input class).
make_w1_10f_tree() {
    local name="$1" body_mode="$2" root="$TMPDIR_LOCAL/$name"
    rm -rf "$root"
    mkdir -p "$root/hooks/lib" "$root/install"
    if [ -d "$AGENTS_DIR/hooks/lib" ]; then
        cp -R "$AGENTS_DIR/hooks/lib/." "$root/hooks/lib/"
    fi
    case "$body_mode" in
        missing) : ;; # no install/codegraph-constants.txt at all (ENOENT)
        garbage) printf 'not-a-valid-constants-file\n@@@garbage@@@\n' > "$root/install/codegraph-constants.txt" ;;
    esac
    printf '%s' "$root/hooks/lib/codegraph-boundary.js"
}

run_w1_10f_case() {
    local case_id="$1" body_mode="$2"
    local boundary_path out
    boundary_path="$(make_w1_10f_tree "w1-10f-$body_mode" "$body_mode")"
    out="$(node -e "
try {
  const b = require(process.argv[1]);
  const env = typeof b.telemetryEnv === 'function' ? b.telemetryEnv() : (b.readConstants ? b.readConstants() : {});
  process.stdout.write(JSON.stringify({
    CODEGRAPH_TELEMETRY: String(env.CODEGRAPH_TELEMETRY),
    DO_NOT_TRACK: String(env.DO_NOT_TRACK),
  }));
} catch (e) {
  process.stdout.write('__ERROR__:' + e.message);
}
" "$boundary_path" 2>&1)"
    if [ "$out" = '{"CODEGRAPH_TELEMETRY":"0","DO_NOT_TRACK":"1"}' ]; then
        pass "$case_id: telemetryEnv() returns the fallback pair CODEGRAPH_TELEMETRY=0 DO_NOT_TRACK=1 when constants ($body_mode) cannot be read"
    else
        fail "$case_id: expected the fallback pair, got '$out'" "constants body: $body_mode"
    fi
}

run_w1_10f_case "W1-10f-behavior (missing)" missing
run_w1_10f_case "W1-10f-behavior (garbage)" garbage
