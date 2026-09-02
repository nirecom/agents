# CodeGraph Operations

CodeGraph is a code-intelligence index (a SQLite knowledge graph of symbols, edges, and files)
exposed to Claude Code as the `mcp__codegraph__codegraph_explore` MCP tool. It is **opt-in**:
off by default, and every part of the workflow degrades silently to Read/Grep when it is absent.

Usage policy for the tool itself (when to call it, what `projectPath` must point at) lives in
[`agents/lib/codegraph-usage.md`](../../agents/lib/codegraph-usage.md). This document covers
setup and day-to-day operation only.

## Enabling — three steps, in order

### 1. Turn the flag on

Set `CODEGRAPH=on` in the agents config `.env` (see the `CODEGRAPH` block in
[`.env.example`](../../.env.example) for the accepted values).

The flag is fail-safe-OFF: only a literal lowercase `on` enables. `off`, unset, empty, an
unrecognized value, or an unreadable config all resolve to OFF. A real environment variable
outranks the `.env` file.

Verify:

```bash
bash bin/get-config-var CODEGRAPH off      # prints: on
```

### 2. Run the installer

The flag alone installs nothing. Re-run the installer so it picks up the new value:

```powershell
C:\git\agents\install.ps1        # Windows
```

```bash
bash install.sh                  # WSL / macOS / Linux
```

This installs the pinned npm package and registers the MCP server:

- `npm install -g --ignore-scripts @colbymchenry/codegraph@<version>` — the version is pinned in
  [`install/codegraph-constants.txt`](../../install/codegraph-constants.txt), which is the single
  source of truth shared by both OS scripts and the MCP registrar.
- `node install/codegraph-mcp.js register` — registers the server through the Claude Code CLI
  (`claude mcp add`), never through the upstream tool's own bootstrap, which would rewrite
  `~/.claude/CLAUDE.md` and inject a prompt hook.

Upstream telemetry is opted out on both paths (`CODEGRAPH_TELEMETRY=0`, `DO_NOT_TRACK=1`).

**Reading the installer output.** `claude mcp add` prints its confirmation without the `--env`
flags, so a line like `Added stdio MCP server codegraph with command: codegraph serve --mcp` does
**not** mean the telemetry opt-out was dropped. A `Removed` immediately followed by `Added` is also
normal — it means an older registration lacked the env pair, so the registrar replaced it. Verify
the real entry instead:

```bash
jq -c '.mcpServers.codegraph' ~/.claude.json
# {"type":"stdio","command":"codegraph","args":["serve","--mcp"],
#  "env":{"CODEGRAPH_TELEMETRY":"0","DO_NOT_TRACK":"1"}}
```

Only an entry matching that exact shape is treated as this installer's own. A hand-written
registration is left untouched — and is never removed when the flag goes back to `off`.

### 3. Build the index — once per worktree

The index lives at `<worktree>/.codegraph/codegraph.db`. It is a **per-worktree artifact on
disk**, not per-session state, so it must be built once for each worktree you actually work in:

```bash
node bin/codegraph-lifecycle.js init --path C:\git\agents
node bin/codegraph-lifecycle.js init --path C:\git\worktrees\2153-env-example\agents
```

Notes:

- `--path` takes the **worktree root** — the directory holding the `.git` file. Worktree paths
  here are two levels (`<WORKTREE_BASE_DIR>/<TASK_NAME>/<REPO_NAME>`), so include the trailing
  repo name. Pointing at the parent creates the index in the wrong place.
- `node bin/...` resolves only when the CWD is the agents repo root; from anywhere else use the
  absolute script path.
- It is **idempotent**. A healthy index short-circuits to a no-op, a broken one is rebuilt
  (`codegraph index -q`, then quarantine and re-init if that fails), an absent one is built
  (`codegraph init -y`). When in doubt, just run it.
- Only worktrees you are actively working in need this. A stale worktree left registered in
  `git worktree list` costs nothing by being skipped.
- The first build takes a while and produces a sizeable file (roughly 15 MB for this repo).

## What happens automatically

Once the flag is on and the binary is installed, these need no operator action:

| Trigger | Effect |
|---|---|
| `/worktree-start` (WS-7a) | Builds the index for the new worktree — step 3 above is already done for anything created this way |
| `hooks/post-checkout`, `hooks/post-merge` | Refreshes the index (`codegraph sync -q`) — **only when a healthy index already exists**; it never builds one from scratch |
| `/worktree-end` cleanup cascade | Stops the worktree's daemon before removing the directory |

The consequence of the middle row: a worktree that pre-dates the flag being turned on never gets
an index from the git hooks alone. That is exactly the gap step 3 fills, and it is a one-time
migration — worktrees created from now on are covered by WS-7a.

## Turning it off

Set `CODEGRAPH=off` in `.env` and re-run the installer. `install/codegraph-mcp.js unregister`
removes the MCP registration, but only when it matches the shape this installer wrote.

Switching to `off` deliberately does **not** uninstall the npm package and does **not** delete any
existing `.codegraph/` index — nothing is destroyed behind your back. Remove those by hand if you
want the disk space back.

`codegraph-lifecycle.js stop` is exempt from the flag: it releases a daemon this framework started,
and the uninstall path runs it precisely because the flag has just turned off.

## Verifying the setup

| Check | Command | Expected |
|---|---|---|
| Flag | `bash bin/get-config-var CODEGRAPH off` | `on` |
| Package | `npm ls -g @colbymchenry/codegraph --depth=0` | version matches `install/codegraph-constants.txt` |
| Binary | `codegraph --version` | resolves on PATH |
| MCP entry | `jq -c '.mcpServers.codegraph' ~/.claude.json` | command/args/env as shown above |
| Index | `ls <worktree>/.codegraph/codegraph.db` | present and non-empty |

## Troubleshooting

**`CODEGRAPH is on but the codegraph command was not found; skipping init.`**
The flag is on but step 2 was never run, or the global npm bin directory is not on PATH. Re-run
the installer.

**`index for <root> is <verdict>; skipping sync.`**
A `sync` found an index that is not healthy. Run `init --path <root>` to repair it — sync
deliberately never repairs, because it fires on every checkout and merge where a wrong verdict
must cost nothing.

**`index for <root> is being built by another process; leaving it alone.`**
Another session is mid-build. Wait for it; do not run a second `init` against the same root.

**`index for <root> is still unusable after a rebuild.`**
The rebuild and quarantine path both ran and the index is still not valid. `codegraph_explore` may
return stale or empty results against that root; agents fall back to Read/Grep, so work is not
blocked. The unusable database is set aside at `<root>/.codegraph/broken/`.

**Nothing at all happens, no output.**
Expected when the flag is off. Every verb exits 0 in that case — a CodeGraph problem must never
halt the pipeline that called it.

## Implementation map

| Concern | File |
|---|---|
| Entrypoint (`init` / `sync` / `stop`) | [`bin/codegraph-lifecycle.js`](../../bin/codegraph-lifecycle.js) |
| Index health verdicts | [`bin/codegraph-lifecycle/index-health.js`](../../bin/codegraph-lifecycle/index-health.js) |
| Daemon identity and kill path | `bin/codegraph-lifecycle/process-identity.js`, `daemon-stop.js` |
| MCP registration | [`install/codegraph-mcp.js`](../../install/codegraph-mcp.js) |
| Version and telemetry constants | [`install/codegraph-constants.txt`](../../install/codegraph-constants.txt) |
| OS installer steps | `install/win/codegraph.ps1`, `install/linux/codegraph.sh` |
| Design rationale | [`docs/architecture/claude-code.md`](../architecture/claude-code.md) |

The `bin/codegraph-lifecycle/` directory is never invoked directly — it holds modules private to
`bin/codegraph-lifecycle.js`, per the Pattern A split in `rules/coding/file-split.md`.
