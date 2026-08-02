# Test Fixture Isolation

Rules for keeping a test's side effects inside its own temp directory.
A test that leaks writes into the developer's real `$HOME` contaminates the
supervisor audit trail and the workflow state store.

## Dual-pin the plans dir

Pin `WORKFLOW_PLANS_DIR` in every place `CLAUDE_WORKFLOW_DIR` is pinned.
Pinning only one of the pair is the contamination bug: hooks resolve the
workflow state from the fixture but the supervisor emitter still resolves
`~/.workflow-plans/` and appends there.

`supervisor-emit.js` refuses to write when exactly one of the two is set
(pristine module-load snapshot; one-line stderr diagnostic; fail-open).

Audit the repo with `bin/check-plans-dir-isolation.sh` — a `W-candidate:` line
means a test pins `CLAUDE_WORKFLOW_DIR`, omits `WORKFLOW_PLANS_DIR`, and
reaches a supervisor-emitting code path. Zero W-candidates is the contract.

Export both once near the top of the test so child `node` processes inherit
them, rather than repeating the pair on each invocation line.

## Unset inherited session IDs

Unset `CLAUDE_SESSION_ID` and `CLAUDE_CODE_SESSION_ID` before spawning a hook.
The parent Claude Code session exports them, so a test that forgets resolves
the live session and mutates its real state file.

## Neutral CWD and fixture project dir

Run from a temp directory, not the worktree: hooks that call
`git rev-parse` otherwise resolve the real repo. Point `CLAUDE_PROJECT_DIR`
at a throwaway `git init` fixture when the code under test needs a repo.

Normalize fixture paths with `cygpath -m` when available so Node receives a
POSIX-style path on Windows.

## Disable git hooks in fixture repos

Every fixture repo created with `git init` must immediately run
`git config core.hooksPath /dev/null`. Otherwise the installed `pre-commit`
hook fires inside the fixture and can block or slow the test.

## LOCAL_SKILL_MD vs SKILL_MD

`SKILL_MD` points at the deployed `$HOME/.claude/` copy — the merged state.
`LOCAL_SKILL_MD` points at the worktree copy — the state under test.

Assertions about changes made in the current worktree must use
`LOCAL_SKILL_MD`; they fail pre-merge otherwise. Use `SKILL_MD` only when the
deployment symlink itself is what the case verifies.
