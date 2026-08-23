# Worker dispatch — the child-process execution contract

What/Why for `bin/worker-dispatch/spawn.js`. The code carries one-line summaries
and points here; this file holds the reasoning. Field types and per-worker
declarations live in `hooks/lib/worker-dispatch-registry.js` (SSOT).

## The three invariants

Every child process the dispatcher starts holds all three:

1. **No shell, ever.** `shell:false` with an argv array. Quoting, `$(...)`,
   backticks and `;`/`&&`/`|` in payload text are inert by construction rather
   than by escaping.
2. **The binary is not payload-derived.** It comes from the registry's fixed
   table — an external command the worker declared in `binaries.external`, or a
   script resolved from an anchor plus a hardcoded relative path. The payload
   never names an executable.
3. **The child env is an allowlist.** `AGENTS_CONFIG_DIR` is set explicitly from
   the resolved ACD anchor and is never inherited, so a poisoned parent env
   cannot redirect a child at a planted checkout.

## Anchors

`anchorRoot()` resolves `acd`, `main-root` and `family-worktree`.
`family-worktree` is the one anchor that deliberately resolves into unreviewed
code, and the only one that can serve a worker whose job IS to execute the
branch under review: `tests/run-all.sh` derives its test directory from its own
location, so a main-root-anchored script runs main's suite no matter what cwd it
is given — i.e. it silently verifies the wrong tree. The widening is bounded —
the root is the validated family worktree, never an arbitrary payload path.

`cwd` is validated (`assertCwdInFamily`) *before* script resolution, because a
`family-worktree`-anchored script resolves against it and must therefore be a
proven family member before it can act as a script root. `scriptExists()`
validates `cwd` unconditionally even though only family-anchored scripts consult
it, so a caller cannot probe an out-of-family path for existence.

## `envScope` — per-call narrowing of `envPassthrough`

`entry.envPassthrough` is the widest set a worker's children may ever inherit.
`envScope` narrows that to what ONE call needs — e.g. `SSH_AUTH_SOCK` reaches
commit-push's real network calls (the pre-push `bootstrapProbe` `git ls-remote`,
the push/fetch steps) and nothing else, so a plain `git commit` (which can
trigger a repo-configured `core.hooksPath` hook) never sees the signing socket,
and a `git rebase` replay (pre-rebase / post-rewrite hooks, merge and smudge
drivers) never sees it either.

Two values, two meanings:

| `envScope` | meaning |
|---|---|
| omitted (`undefined`) | no narrowing intended — full `envPassthrough`, unchanged legacy behavior |
| an array | exactly the named subset |
| anything else | **throws** |

The throw is the point. Before it existed, a present-but-malformed value (a bare
string from a typo such as `envScope: "SSH_AUTH_SOCK"`) fell back to the FULL
passthrough — every credential the entry declares silently reaching a child the
author had meant to starve. That is a fail-open, and a narrowing mechanism that
fails open is worse than none, because the call site reads as if it is scoped.

`extraEnv` is checked against the *narrowed* set, not the full one: a var a call
explicitly passes must also be one that call is scoped for.

## Why `input` (stdin) exists

`input` is the ONLY way payload-derived free text reaches a child. As argv it
would still be inert (`shell:false`), but it would also be visible in the
process table and subject to the platform command-line length limit — Windows
`CreateProcess` caps a whole command line at 32767 bytes, so a large commit
message or PR body would fail the SPAWN, after the commit and push had already
landed. `git commit -F -` and `gh pr create --body-file -` send it on stdin
instead.

Opting in is per-call and the default is unchanged: with `input` omitted the
child gets `stdio[0] = "ignore"` exactly as before, so the pre-existing workers
see byte-for-byte identical behaviour. `spawnOpts.input` is set only when opted
in — `spawnSync` treats a present-but-`undefined` `input` the same as an absent
one today, but relying on that would make the no-input path depend on an
implementation detail instead of on the option being absent.
