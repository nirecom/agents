# TL3-hook-forge-target-ownership.sh — rationale

## What this seam test proves that the TL2 suite cannot

`tests/feature-2053-forge-target-ownership.sh` feeds the hook synthetic stdin
as a node subprocess: that proves the DECISION but not that a live session
ever routes a `gh issue create` to it. The failure modes invisible there are
(1) the hook registered for the wrong event/matcher or not at all, (2) the
Bash family not reaching it, and (3) an EARLIER hook in the chain denying the
command so the ask the guard intended is never the verdict the user sees.

Layer: TL3 (live `claude -p`, real PreToolUse dispatch, real settings.json
chain).

## Fixture settings.json

Generated from the repository's own `settings.json` — every PreToolUse entry
whose matcher covers Bash is copied in production order and only wrapped with
a logging shim. A self-registered throwaway entry would prove the hook works
when someone wires it correctly; copying production proves it IS wired, and
runs it against the same neighbours (`enforce-worktree.js` and its
`handle-bash-write.js`, `enforce-issue-close.js`, `workflow-gate.js`) it ships
beside.

## ROUND-2 C1 — the fixture must be REACHABLE, not merely wired

`enforce-worktree.js` runs ahead of the guard in the same chain and blocks a
bare `gh issue create` whenever the command's repo root is a MAIN checkout
(`hooks/enforce-worktree/handle-bash-write.js`). A `git init` temp dir is a
main checkout, so an earlier fixture had both live turns preempted before the
guard ever ran, and every ask/allow assertion would have been vacuous.

The fixture is therefore a MANAGED LINKED WORKTREE (`git worktree add`),
which is the sanctioned shape, and the C1-P preflight asserts the existing
gate really does permit it — proven by running `enforce-worktree.js` itself
over the two exact payloads, before any agent is spawned.

## SAFETY (step 14, C57)

This test drives a live agent at a command whose whole purpose is to FILE A
GITHUB ISSUE. Three independent mitigations, all required:

- (b) [chosen primary] `gh` is shadowed on PATH by a stub that only appends
  its argv to a log. Every PATH entry that carries a real `gh` is REMOVED
  from the turn's PATH (round-2 C3), so the stub is not merely first — it is
  the only `gh` reachable by any route, for the whole session.
- (c) [round-2 C3] every GitHub credential variable is stripped from the
  turn env and `GH_CONFIG_DIR` is redirected at an empty temp dir, so even a
  hypothetical real `gh` would be unauthenticated. The stub records what it
  actually saw, and the assertions read that record.
- (a) [last layer] the fixture's origin names a REAL-looking login but a
  repo that does not exist, so even a hypothetical escape to a real `gh`
  404s.

(b)+(c) are primary because they hold even if the hook allows, if the
harness ignores an ask, and under `--dangerously-skip-permissions`. (a)
alone would not: it still lets a real network write be attempted. The stub
NEVER performs I/O.
