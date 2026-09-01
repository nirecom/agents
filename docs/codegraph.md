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

The re-run removes the MCP registration *only if this installer wrote it* — same command, args, and
telemetry env. A `codegraph` entry you registered by hand is left alone. The npm package and any
existing `.codegraph/` index directories are deliberately left in place; remove them yourself with
`npm uninstall -g @colbymchenry/codegraph` and `codegraph uninit`.

## Telemetry

Upstream CodeGraph reports usage to `https://telemetry.getcodegraph.com/v1/events` and defaults it on,
and this installer is non-interactive, so nothing would ever ask you. The registration therefore carries
`--env CODEGRAPH_TELEMETRY=0 --env DO_NOT_TRACK=1`, and both installer scripts export the same pair.
The values live in `install/codegraph-constants.txt`.

## Cautions

**Never run `codegraph install` or `codegraph uninstall`.** They overwrite `~/.claude/CLAUDE.md` — a
symlink to this repo — with a plain file, and add a `UserPromptSubmit` prompt-hook. This framework
registers the MCP server itself instead.

Automatic index refresh on checkout and merge needs Node 22.5+ (`node:sqlite`). On older Node the index
still builds, but the git hooks skip the refresh.
