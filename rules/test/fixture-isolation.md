---
paths:
  - "tests/**"
---

# Test Fixture Isolation

Rules for keeping a test's side effects inside its own temp directory.
A test that leaks writes into the developer's real `$HOME` contaminates the
supervisor audit trail and the workflow state store.

## Dual-pin the plans dir

Pin `WORKFLOW_PLANS_DIR` in every place `WORKFLOW_STATE_DIR` is pinned.
Pinning only one of the pair is the contamination bug: hooks resolve the
workflow state from the fixture but the supervisor emitter still resolves
`~/.workflow-plans/` and appends there.

`supervisor-emit.js` refuses to write when exactly one of the two is set
(pristine module-load snapshot; one-line stderr diagnostic; fail-open).

Pin both once, at top level, before the first line that runs a hook or bin entrypoint: `export WORKFLOW_STATE_DIR=… WORKFLOW_PLANS_DIR=…`, or `harness_isolate <tmp>` (pins both).
A pin inside a function body is no pin; a function defined before the pin counts as running at its definition line.
Inline-only pins (`WORKFLOW_STATE_DIR=… node …` per call) and pins after the first exec are violations.
Point the cleanup trap at a `readonly` tmp-root variable, never at a pinned variable a case may re-point.
For a default-path case, clear the pin on that one call with `env -u WORKFLOW_STATE_DIR …`.

`bin/check-plans-dir-isolation.sh` is the gate (pre-commit `--staged`, CI whole tree): it scans `tests/**/*.sh` recursively and rejects any tracked file still carrying the retired variable name.
A sourced helper inherits a pin only through a statically resolvable `source` path (`$(dirname "$0")`, `${BASH_SOURCE%/*}`, a once-assigned dir variable) placed after the parent's pin, from every resolved parent; otherwise pin in the helper itself.

## Unset inherited session IDs

Unset `CLAUDE_CODE_SESSION_ID` before spawning a hook.
The parent Claude Code session exports it, so a test that forgets resolves the live session and mutates its real state file.

Point `CLAUDE_TRANSCRIPT_BASE_DIR` at an empty fixture directory whenever the
code under test can reach the default resolution chain: its last stage picks
the most recently modified transcript, which is some other live session.

## Neutral CWD and fixture project dir

Run from a temp directory, not the worktree: hooks that call
`git rev-parse` otherwise resolve the real repo. Point `CLAUDE_PROJECT_DIR`
at a throwaway `git init` fixture when the code under test needs a repo.

Normalize fixture paths with `cygpath -m` when available so Node receives a
POSIX-style path on Windows.

## Decoy agents root

`tests/lib/harness.sh` points `AGENTS_MAIN_ROOT` at a stub tree on load, so a test that reaches a tool through it fails instead of running the installed copy.
Call `root_decoy_use_real_main_root` only in a test that must read the real main worktree; `bin/check-root-names.sh` rejects the call in any file the classification table does not list.

## Disable git hooks in fixture repos

Every fixture repo must have `core.hooksPath` set to `/dev/null` before anything runs in it.
A repo made by `git init` sets it on the next line.
A repo made by copying an existing `.git` inherits it from the template repo, so set it once there and never per copy.
Otherwise the installed `pre-commit` hook fires inside the fixture and can block or slow the test.

## LOCAL_SKILL_MD vs SKILL_MD

`SKILL_MD` points at the deployed `$HOME/.claude/` copy — the merged state.
`LOCAL_SKILL_MD` points at the worktree copy — the state under test.

Assertions about changes made in the current worktree must use
`LOCAL_SKILL_MD`; they fail pre-merge otherwise. Use `SKILL_MD` only when the
deployment symlink itself is what the case verifies.
