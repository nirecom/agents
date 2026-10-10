# Worker Dispatch Call Protocol

Shared by every caller of a plain-script worker. Worker names, payload fields, defaults, and stdout shape: `hooks/lib/worker-dispatch-registry.js` (SSOT).

WD-1. Resolve the invocation paths: `node "$AGENTS_MAIN_ROOT/bin/worker-dispatch-paths"` (pass the target repo directory as the sole argument when the worker acts on a sibling repository). Read `DISPATCH` / `TARGET_MAIN_ROOT` / `PLANS_DIR` from its output.

WD-2. Write the draft (Write tool) to `<PLANS_DIR>/<session-id>-worker-<worker-name>[-<seq>].draft.json` (`-<seq>` when one skill dispatches the same worker more than once; unresolvable session id → `unknown-session`), then publish it in one standalone call: `node "$AGENTS_MAIN_ROOT/bin/worker-dispatch-payload" --session <session-id> --worker <worker-name> [--seq <n>] --draft <draft-path>`. Its stdout `PAYLOAD=<path>` is the WD-3 `<payload-path>`. Never put a control path (state/outcome file) in the payload — the dispatcher derives it.

WD-3. Dispatch (Bash) — this is the ENTIRE command, with the paths from WD-1 and WD-2 as literal absolute paths:

    node "<DISPATCH>" <worker-name> "<TARGET_MAIN_ROOT>" "<payload-path>"

WD-4. Read the rendered contract from the command's stdout. Exit 0 always accompanies it, including for validation failures (`status: failed`); a payload that was already dispatched also exits 1 — publish a new `--seq` instead. Exit 2 means the invocation itself was unusable — wrong arity, unknown worker name, or a `<TARGET_MAIN_ROOT>` that is not a main worktree — and no worker ran.

WD-5. One dispatch call acts on exactly one repository. For a sibling repo, re-run WD-1 against that repo and dispatch again.

## Naming

Name the form on every dispatch line — the three kinds are spawned by different mechanisms, and an unmarked name leaves the reader guessing which one runs.

- Plain-script worker (this protocol): put the word worker next to the name — the `doc-append` worker.
- LLM subagent (Task tool, `agents/<name>.md`): put the word subagent next to the name — the `skip-verifier` subagent.
- Skill (`skills/<name>/SKILL.md`): use the slash form — /commit-push.

Carry exactly one marker per line; two markers are as ambiguous as none.

## Rules

- Never add a redirect, pipe, `&&`, `;`, `cd`, env prefix, or `$VAR` to the WD-3 command — `enforce-worktree` sanctions only the bare canonical form, and any addition makes it a blocked write from the main worktree.
- Never write the payload directly — only via `bin/worker-dispatch-payload`; the guard and the dispatcher refuse any other payload path.
- The guard never reads the payload; the dispatcher validates every field against its own trust anchors. A field it rejects is reported as `status: failed`, never silently dropped.
- Never retry a `status: failed` by loosening the payload — surface the summary and stop.
