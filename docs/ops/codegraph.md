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

Steps 1 and 2 are global and belong to whoever owns the machine's config. Step 3 is per-worktree
and has to happen in each worktree separately, including the main one. It is written up for that
audience below: [One-time worktree init](#one-time-worktree-init).

Point other sessions at that section rather than restating the command — it is the single source
of truth for the procedure.

## One-time worktree init

**Audience: a session working inside a worktree that already existed when CodeGraph was turned
on.** Run this once for your worktree. Nothing else is asked of you.

### Why this is not automatic

The index lives at `<worktree>/.codegraph/codegraph.db` — a **per-worktree file on disk**, not
per-session state. Two mechanisms normally keep it current, and neither covers a worktree that
predates the flag:

- `/worktree-start` (WS-7a) builds the index for worktrees **it creates**. Yours was not created
  by it, or was created before the flag went on.
- `hooks/post-checkout` and `hooks/post-merge` **refresh an index that already exists**. They
  deliberately never build one from scratch, because they fire on every checkout and merge where
  a wrong guess must cost nothing.

So the very first build is the one thing left to do by hand. It is a one-time migration —
worktrees created from here on are covered by WS-7a.

### The command

From inside your worktree:

```bash
node "$AGENTS_CONFIG_DIR/bin/codegraph-lifecycle.js" init --path "$(git rev-parse --show-toplevel)"
```

Or with the path written out:

```bash
node C:\git\agents\bin\codegraph-lifecycle.js init --path C:\git\worktrees\2153-env-example\agents
```

- `--path` takes the **worktree root** — the directory holding the `.git` file. Worktree paths in
  this repo are two levels (`<WORKTREE_BASE_DIR>/<TASK_NAME>/<REPO_NAME>`), so include the
  trailing repo name. Pointing at the parent puts the index in the wrong place.
- A bare `node bin/...` resolves only when the CWD is the agents repo root. From a worktree, use
  the absolute script path as shown. Your worktree's own checkout of the script works too — it is
  the same tracked file.

### What to expect

- **It is idempotent.** A healthy index short-circuits to a no-op, a broken one is rebuilt, an
  absent one is built. When in doubt, just run it.
- Silence means the index was already fine. `index ready for <root>` means it built one.
- The first build takes a few minutes and produces a sizeable file (roughly 15 MB for this repo).
- It always exits 0. A CodeGraph problem must never halt the pipeline that called it.

Verify afterwards:

```bash
ls .codegraph/codegraph.db
```

Any warning on stderr is explained under [Troubleshooting](#troubleshooting).

### When you do *not* need this

- Your worktree was created by `/worktree-start` after the flag went on — WS-7a already did it.
- A worktree you are not actively working in. A stale entry in `git worktree list` costs nothing
  by being skipped; there is no need to sweep them all.
- A second session entering a worktree that is already initialized. The index is keyed to the
  path, not to the session, so re-running is a no-op rather than a requirement.

### If you skip it

Nothing breaks. `mcp__codegraph__codegraph_explore` degrades silently to Read/Grep when the index
is missing, per [`agents/lib/codegraph-usage.md`](../../agents/lib/codegraph-usage.md). You simply
do not get the faster lookups in that worktree.

## What happens automatically

Once the flag is on and the binary is installed, these need no operator action:

| Trigger | Effect |
|---|---|
| `/worktree-start` (WS-7a) | Builds the index for the new worktree |
| `hooks/post-checkout`, `hooks/post-merge` | Refreshes the index (`codegraph sync -q`) — only when a healthy index already exists |
| `/worktree-end` cleanup cascade | Stops the worktree's daemon before removing the directory |

Between them these two rows leave exactly one gap, which
[One-time worktree init](#one-time-worktree-init) covers.

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
| Binary | see paragraph below | resolves for spawnSync |
| MCP entry | `jq -c '.mcpServers.codegraph' ~/.claude.json` | command/args/env as shown above |
| MCP server responds | in a Claude Code session, run any tool under the `codegraph` MCP server (e.g. ask it to explore a symbol) | the server responds instead of "server not found" / "server failed to start" |
| Index | `ls <worktree>/.codegraph/codegraph.db` | present and non-empty |

**Why not just run `codegraph --version` in a shell?** On Windows, npm installs `codegraph` as three
files sharing one basename: an extensionless POSIX shim, a `.cmd` batch shim, and a `.ps1` shim. A
shell (PowerShell, cmd.exe) resolves `.cmd`/`.ps1` transparently, so a manual check can succeed even
when the actual failure mode is that Node's `spawnSync` — which every part of this framework uses,
without a shell — cannot spawn a `.cmd`/`.bat` file directly. Verify the way Claude Code itself
resolves the binary instead, run from the repo root (the require path below is relative, not
`$AGENTS_CONFIG_DIR`-based, so it works in a plain shell with no environment set up). Any `r.error`
(not just `ENOENT`) means the CLI did not resolve for `spawnSync` — `EPERM`/`EACCES`/`EINVAL` are
just as real a failure as a missing binary and must not be reported as success:

```bash
node -e "const {spawnShimmedCli}=require('./hooks/lib/spawn-shimmed-cli'); const r=spawnShimmedCli('codegraph',['--version'],{stdio:'ignore'}); console.log(r.error ? 'NOT RESOLVED for spawnSync: ' + r.error.code : 'resolves for spawnSync')"
```

## Troubleshooting

**`CODEGRAPH is on but the codegraph command was not found; skipping init.`**
The flag is on but step 2 was never run, or the global npm bin directory is not on PATH. Re-run
the installer. On Windows, reproduce it with the Node one-liner above rather than with a shell:
if that one-liner fails while `codegraph.cmd` / `codegraph.ps1` work in PowerShell, the binary is
installed but not resolvable for `spawnSync`, and a non-`ENOENT` `r.error.code` points away from
PATH resolution entirely (permissions or a corrupt shim, not a missing install).

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
| Windows shim resolution for `codegraph`/`claude` (no shell, no direct `.cmd`/`.bat` spawn) | [`hooks/lib/spawn-shimmed-cli.js`](../../hooks/lib/spawn-shimmed-cli.js) |
| Version and telemetry constants | [`install/codegraph-constants.txt`](../../install/codegraph-constants.txt) |
| OS installer steps | `install/win/codegraph.ps1`, `install/linux/codegraph.sh` |
| Design rationale | [`docs/architecture/claude-code.md`](../architecture/claude-code.md) |

The `bin/codegraph-lifecycle/` directory is never invoked directly — it holds modules private to
`bin/codegraph-lifecycle.js`, per the Pattern A split in `rules/coding/file-split.md`.
