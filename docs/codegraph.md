# CodeGraph Integration

[CodeGraph](https://www.npmjs.com/package/@colbymchenry/codegraph) is a third-party code-intelligence
tool that serves planning and review agents a pre-built symbol graph instead of a Read/Grep sweep.
This repository only wires it in; it is never a required dependency.

## Enabling

Set `CODEGRAPH=on` in `.env`, then **re-run** `install.ps1` / `install.sh`. The installer installs the
npm package at the version pinned in `install/codegraph-constants.txt` (with `--ignore-scripts`, so no
upstream lifecycle script runs) and registers the MCP server with `claude mcp add`.

Close Claude Code while the installer runs — it writes `~/.claude.json`, which a live session also writes.

## Disabling

Set `CODEGRAPH=off` and **re-run the installer again**; editing `.env` alone unregisters nothing.

The re-run removes the MCP registration *only if this installer wrote it* — proven by the
`AGENTS_CODEGRAPH_MCP_OWNER=agents-framework` env marker the registration carries. A `codegraph` entry
you registered by hand is left alone. The npm package and any existing `.codegraph/` index directories
are deliberately left in place; remove them yourself with `npm uninstall -g @colbymchenry/codegraph`
and `codegraph uninit`.

## Telemetry

Upstream CodeGraph reports usage to `https://telemetry.getcodegraph.com/v1/events` and defaults it on.
This framework ships that default unchanged: the registration carries
`--env CODEGRAPH_TELEMETRY=1 --env DO_NOT_TRACK=0`, and `bin/codegraph-lifecycle.js` passes the same
pair to every codegraph subprocess it spawns. The values live in `install/codegraph-constants.txt`,
which is the only control surface for a codegraph process this framework launches.

The two keys are independent, not one switch: upstream reads `DO_NOT_TRACK` first — any value other
than unset, empty, `0` or `false` opts out of everything — and only then `CODEGRAPH_TELEMETRY`.
`DO_NOT_TRACK` is an industry-wide name this framework has no standing to set on your behalf, so it
ships as `0`.

To turn telemetry off everywhere: set `CODEGRAPH_TELEMETRY=0` in `install/codegraph-constants.txt`,
re-run the installer, and run `codegraph telemetry off` once for the codegraph you start by hand.
While the constants file ships `CODEGRAPH_TELEMETRY=1`, every installer run deletes
`~/.codegraph/telemetry.json` so the shipped value, not a stale saved choice, is what applies.

The installer scripts deliberately do **not** export the pair into their own process. `install.ps1`
runs the Windows step in-process (`& ...codegraph.ps1`), so exporting it would leave the pair in the
caller's shell for the rest of its life — breaking, among other things, Claude Code's Remote Control
when the value opts out.

## Cautions

**Never run `codegraph install` or `codegraph uninstall`.** They overwrite `~/.claude/CLAUDE.md` — a
symlink to this repo — with a plain file, and add a `UserPromptSubmit` prompt-hook. This framework
registers the MCP server itself instead.

**The per-prompt context comes from this repo's own hook, not upstream's.** Upstream's
`codegraph install` is still never called; `hooks/codegraph-context-inject.js` runs the same CLI
subcommand and forwards what it prints, so the output is adopted without the config writes.

**The hook stays silent for prompts sent from your home directory or a filesystem root**, which is
upstream's own exclusion ported over. Every other cwd behaves as upstream designed: if a project
manifest happens to sit in a non-project parent (`C:\git`, `~/work`) with indexed projects beneath
it, the front-load (one project) or nudge (several, listed by name) can still fire there.

Automatic index refresh on checkout and merge needs Node 22.5+ (`node:sqlite`). On older Node the index
still builds, but the git hooks skip the refresh.
