# agents Repository Development Conventions

Conventions that apply only when working **inside the agents repository itself**
(editing skills, hooks, rules, agents, bin, or docs of this repo). Not loaded
globally; consult on demand via the pointer in `CLAUDE.md`.

## bin/ node-misinvocation guard envelope

Background: an extensionless `bin/` bash script launched with `node` instead of
bash used to collapse into a bare `SyntaxError` with rc=1 and empty stdout, which
a caller could not tell apart from "the variable was simply unset" (#1532). So
that the mistake is self-detected at run time, the affected scripts carry a
polyglot envelope — valid bash and valid JavaScript at once — of 12 lines after
the shebang plus 2 lines at end of file.

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
an identical byte sequence (isomorphism check G1 fails otherwise), and updating
`HEAD_LINES` / `TAIL_LINES` / `ENVELOPE_LINES` in
`tests/fix-1532-node-guard/common.sh` to the new measured geometry. The in-file
comment is deliberately two lines and points here — this document is the only
place the mechanism is explained, so it must not be restated in the five scripts.
Extending the
set means adding the new target to `TARGETS` in
`tests/fix-1532-node-guard/common.sh` and adding one more dispatcher at
`tests/fix-1532-node-guard-<name>.sh` (coverage check G6 fails otherwise).

## Consolidated test suites: one dispatcher, sourced fragments

Background: a hook that accumulates cases over many issues ends up with one test
file per issue, and each file carries its own private copy of the same harness —
fixture builders, payload assembly, decision helpers. Thirteen files targeted
`hooks/enforce-worktree.js` that way. The duplication costs tokens on every read
and makes a harness fix a thirteen-place edit.

The shape that replaces it: a dispatcher `tests/<name>.sh` owns the harness and
sources fragments from `tests/<name>/`. `tests/main-enforce-worktree-guard.sh`
is the reference implementation.

**Fragments are deliberately not runnable on their own.** `tests/run-all.sh`
globs `tests/*.sh`, and `*` does not cross `/`, so a fragment is invisible to the
runner while the dispatcher is not. That is the mechanism that keeps each case
counted exactly once. A fragment has no harness of its own and fails immediately
if invoked directly.

**Fragment-local helpers and variables carry a short prefix** (`hb_`, `wl_`,
`br_`, …). Every fragment is sourced into the same shell, so an unprefixed name
silently overwrites a sibling's.

**The gate when consolidating is case-identifier preservation.** Capture the
`PASS: ` / `FAIL: ` / `SKIP: ` lines before and after and compare them as
multisets; they must match. Normalize embedded temp paths first — an identifier
that interpolates a per-run temp directory never matches verbatim. A case that
changes wording is a case that silently stopped being the case it was.

**Deciding not to consolidate is a recordable decision.**
`bin/audit-tests.sh --dup-groups` lists files sharing a `# Tests:` group; tag a
file that stays separate on purpose with `dup-group-keep:<reason>` (`cross-hook`,
`distinct-layer`, `size-hard-limit`). Scope and tag vocabulary:
`skills/_shared/test-design.md`.
