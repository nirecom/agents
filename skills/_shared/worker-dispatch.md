# Worker Dispatch Call Protocol

Shared by every caller of a plain-script worker. Worker names, payload fields, defaults, and stdout shape: `hooks/lib/worker-dispatch-registry.js` (SSOT).

WD-1. Resolve the invocation paths: `node "$AGENTS_CONFIG_DIR/bin/worker-dispatch-paths"` (pass the target repo directory as the sole argument when the worker acts on a sibling repository). Read `DISPATCH` / `MAIN_ROOT` / `PLANS_DIR` from its output.

WD-2. Write the payload (Write tool) to `<PLANS_DIR>/<session-id>-worker-<worker-name>.json`; append `-<seq>` when one skill dispatches the same worker more than once. Session id unresolvable → use `unknown-session`. PLANS_DIR sits outside every git repo, so `enforce-worktree` does not apply and no mkdir is needed.

WD-3. Dispatch (Bash) — this is the ENTIRE command, with all three arguments as the literal absolute paths from WD-1:

    node "<DISPATCH>" <worker-name> "<MAIN_ROOT>" "<payload-path>"

WD-4. Read the rendered contract from the command's stdout. Exit 0 always accompanies it, including for validation failures (`status: failed`). Exit 2 means the invocation itself was unusable — wrong arity, unknown worker name, or a `<MAIN_ROOT>` that is not a main worktree — and no worker ran.

WD-5. One dispatch call acts on exactly one repository. For a sibling repo, re-run WD-1 against that repo and dispatch again.

## Rules

- Never add a redirect, pipe, `&&`, `;`, `cd`, env prefix, or `$VAR` to the WD-3 command — `enforce-worktree` sanctions only the bare canonical form, and any addition makes it a blocked write from the main worktree.
- Never place the payload outside PLANS_DIR — the guard refuses the path.
- The guard never reads the payload; the dispatcher validates every field against its own trust anchors. A field it rejects is reported as `status: failed`, never silently dropped.
- Never retry a `status: failed` by loosening the payload — surface the summary and stop.
