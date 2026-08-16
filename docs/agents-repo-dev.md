# agents Repository Development Conventions

Conventions that apply only when working **inside the agents repository itself**
(editing skills, hooks, rules, agents, bin, or docs of this repo). Not loaded
globally; consult on demand via the pointer in `CLAUDE.md`.

## bin/ node-misinvocation guard envelope

Background: an extensionless `bin/` bash script launched with `node` instead of
bash used to collapse into a bare `SyntaxError` with rc=1 and empty stdout, which
a caller could not tell apart from "the variable was simply unset" (#1532). So
that the mistake is self-detected at run time, the affected scripts carry a
polyglot envelope — valid bash and valid JavaScript at once — of 18 lines after
the shebang plus 4 lines at end of file.

Five scripts carry it: `bin/get-config-var`, `bin/confirm-off`,
`bin/resolve-session-id`, `bin/resolve-worktree-path`, `bin/is-github-dotcom-remote`.

**Permanent syntax reservation**: the bodies of those five must never contain the
two-character block-comment terminator (an asterisk followed by a slash). The
JavaScript block comment opened by the envelope head is closed only by the last
line of the file; closing it early makes everything after it parse as JavaScript
and `node --check` fails. The constraint applies inside comments and prose too.

**Shape of the diagnostic**: it is written only through
`require("fs").writeSync(2, ...)`, and the process ends naturally after setting
`process.exitCode = 70` — never via `process.exit()`. The reason is that
`process.stderr.write` can be asynchronous depending on the environment, and
forcing exit right after an asynchronous write can drop the diagnostic itself
(behavior stated explicitly in the Node.js documentation). Reverting to
`process.stderr.write` is prohibited. EAGAIN is retried up to a bound, any other
error gives the diagnostic up — the contract is that exit code 70 always survives.

**What breaks when this is violated**: `node --check bin/<name>` (syntax
reservation) and `tests/fix-1532-node-guard-*.sh` (envelope shape, the diagnostic,
and byte-level invariance of the bash side).

**When editing**: changing the head or tail means updating all five at once with
an identical byte sequence (isomorphism check G1 fails otherwise). Extending the
set means adding the new target to `TARGETS` in
`tests/fix-1532-node-guard/common.sh` and adding one more dispatcher at
`tests/fix-1532-node-guard-<name>.sh` (coverage check G6 fails otherwise).
