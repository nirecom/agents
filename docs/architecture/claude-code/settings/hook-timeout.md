# PreToolUse Hook Timeout and Decision Time Limit

Owner of two facts for every hook registered under `PreToolUse` in `settings.json`: whether it is an allow-deny hook, and whether it carries a decision time limit. Per-hook behavior contracts stay in [hooks.md](hooks.md); the timeout values themselves live in `settings.json` and `hooks/lib/decision-time-limit.js`.

## Why this exists

Claude Code cancels a hook that runs past its `timeout`, and a cancelled hook's decision is simply lost. Losing a deny lets the command through; losing an allow turns into a permission dialog (interactive) or a refusal (headless). Under concurrent tool calls this happened often enough to interrupt the user (#2676). Two changes answer it:

- every light allow-deny hook runs inside one process, `hooks/merged-allow-deny.js`, so fewer node processes start per tool call;
- each heavy allow-deny hook stops itself before the `timeout` and asks, instead of being cancelled with no decision.

## Terms

- **allow-deny hook**: a hook with at least one output path carrying a permission decision: `hookSpecificOutput.permissionDecision` (`deny` / `ask` / `allow`) or the legacy top-level `decision` (`block` / `approve`).
- **non-allow-deny hook**: a hook whose output never carries a permission decision (it only rewrites input through `updatedInput`, displays context, or records).
- **decision time limit**: the time, counted from the hook's own process start, by which an allow-deny hook must have decided; reaching it prints `ask`.

## Hook `timeout`, as Claude Code applies it

Observed in gate 1 (a) of #2676 ([issue comment](https://github.com/nirecom/agents/issues/2676#issuecomment-6288155952)):

- The clock starts when the hook process starts; all hooks matching one tool call start in parallel, so they share the machine and slow each other under load.
- A hook that reaches its `timeout` is cancelled and counts as "no decision". A cancelled deny does not take effect; a `permissions.allow` rule still allows the command.
- Across hooks, `ask` beats `allow`; a cancelled hook does not cancel another hook's `allow`.
- In headless mode, `permissionDecision: "allow"` and the legacy `{decision:"approve"}` both run the command; no output or `{}` is refused. Interactive mode runs on `approve` as well.
- A cancellation appears only in the transcript, as an `attachment` of type `hook_cancelled` (hook name, tool use id, event, command, duration, timed-out flag, timeout). It is not in the stream-json output, and it is written after PostToolUse for that tool call.

The `timeout` value of each registration is in `settings.json`; `tests/hooks/feature-2676-hook-timeout-relation.js` checks that it stays well above the decision time limit.

## Decision time limit

`hooks/lib/decision-time-limit.js` owns the limit and its value (the value's grounds are cited there).

- **Relation to the hook `timeout`**: the hook `timeout` counts from the hook command's launch, shell start included; the limit counts from node's process uptime, which excludes the shell launch, so its clock starts slightly later. The limit (10 s) lies inside the 15 s `timeout`, and the 5 s margin covers that gap. The hook asks when the limit is reached; the time left until the `timeout` is room for node start, output and exit before Claude Code cancels the hook.
- **Value**: 10 s, above the worst measured ordinary decision. Under load from 7 parallel sessions that rose to about 8.7 s (`block-case-markers`) and 8.0 s (`enforce-worktree`), as wall-clock `durationMs` in Claude Code transcripts, node start included. The 5 s margin is estimated (light hooks took at most about 1.75 s end to end); the decision timing log below measures it. `hooks/lib/decision-time-limit.js` cites the measurements.
- **Anchor**: `armDecisionTimeLimit()` builds a deadline from the process start time (`hooks/lib/hook-deadline.js`), not from the moment it is called, so node start-up and module loading count. Only a hook entry point arms it, once per process.
- **Checks**: the hook calls `checkDecisionTime(<check name>)` before each costly check. Every child process on the decision path goes through `hooks/lib/limited-child-process.js`, which, while the limit is armed, replaces the caller's `timeout` with the time left and refuses to start a child when too little is left.
- **On reaching the limit**: the hook prints `ask` with a reason naming the hook and the unfinished check (`<hook>: decision time limit (<limit> ms) reached before <check> finished; asking instead of deciding`) and exits at once, so no `catch` in the caller can turn the timeout into an approve.
- **Why ask**: the user sees one dialog naming the slow check, instead of a cancelled hook whose deny silently vanishes or whose allow silently becomes a prompt.
- **Known limit**: while the limit is armed, a child's stdio goes through temporary files (a grandchild holding a pipe would keep the call from returning). Writing the input file and reading the output back run outside the child's `timeout`; the read is bounded by `maxBuffer`, and a call that comes back with no time left asks. A synchronous write or read that stalls on a slow disk is not interrupted; the hook `timeout` and the cancellation notice below cover that case.
- **Known limit**: while the limit is armed, a caller's own short-timeout fallback (2-5 s, fail-open paths included) no longer fires; a hung child asks once the time left runs out instead. A fallback that decided allow on its own timeout would skip the ask (security finding N1).

## Decision timing log

The 5 s margin is an estimate, so every armed allow-deny hook process records its timing at exit; a process that never arms writes nothing. The callers stay unchanged: `armDecisionTimeLimit()` registers the exit listener once.

- **File**: `hook-decision-timing.jsonl` under `$AGENTS_STATE_DIR/logs`, or `~/.agents/logs` when `AGENTS_STATE_DIR` is unset; size-rotating (`hooks/lib/jsonl-rotating-log.js`).
- **Fields**: `hookName`, `pid`, `startedAt` (process start, epoch ms), `armedAtMs` and `exitAtMs` (process uptime in ms at arm and at exit), `asked` (true when the limit wrote the `ask`).
- **Use**: match a line to the transcript's `durationMs` for the same hook by hook name and end time (`startedAt + exitAtMs`). `durationMs - exitAtMs` is the time outside node's uptime: launch before node start, plus output and exit. Its worst value is what the 5 s margin has to cover.
- **Failure**: the write waits at most 200 ms for the lock; any failure is dropped silently and never changes the decision, the output or the exit code.
- **Review**: once enough lines have been collected under parallel load, revisit the limit and the margin against the measured worst values.

## Cancellation notice

Because a cancel is visible only in the transcript, `hooks/lib/hook-cancel-notice.js` reads the `hook_cancelled` records at the next UserPromptSubmit (`hooks/user-prompt-submit-mechanism-check.js`) and tells the user which hook was cancelled. It is a report after the fact; it cannot restore the lost decision.

- Each cancel is told once: a per-session cursor keeps the read position. The first read in a session scans only the last 4 MiB of the transcript; later reads cover everything after the cursor.
- A record marked `timedOut: false` (an interrupt, not the timeout) is not reported.
- **Known limit**: the cursor is saved before the hook prints the notice, so a hook killed between the two loses that notice instead of repeating it.

## Merged allow-deny hook

`hooks/merged-allow-deny.js` runs `bash-guard`, `preuse-auto-approve`, `block-dotenv`, `block-credentials` and `block-capture-echo` in one process. It is registered once per matcher group (`--matcher-group primary` and `--matcher-group monitor-worktree`); `hooks/merged-allow-deny/members.js` owns which tools route to which member.

- Members decide on the parsed input in order; the first deny ends the run. Results merge as deny > ask > allow > approve > none (`hooks/merged-allow-deny/merge.js`); `none` never turns into `approve`.
- Unreadable or malformed input answers per member as each standalone hook did (unreadable stdin denies for `block-dotenv`, `block-credentials` and `bash-guard`; everything else fails open), with at most one stderr diagnostic.
- A member whose judge throws: `block-dotenv` and `block-credentials` answer `ask` naming the member; the others answer nothing.
- Each member's `hooks/<name>.js` still runs alone through the same runner, for tests and manual use.

## Classification

<!-- lang-check: ignore — the classification table's CJK header and limit cells are the keys tests/hooks/feature-2676-hook-classification/table.js parses. -->

Traced by running each hook on a deny-side and a permitted-side input with every child-process launch logged (`tests/hooks/feature-2676-hook-classification/oracle.js` holds the inputs), plus a read of each hook's decision path. A row "あり" (with limit) means the hook launches a child process or scans files while deciding; its entry point must arm the limit.

| hook | 分類 (classification) | 上限時間 (decision time limit) | 理由 (reason) |
|---|---|---|---|
| `merged-allow-deny`、`bash-guard`、`preuse-auto-approve`、`block-dotenv`、`block-credentials`、`block-capture-echo` | allow-deny hook | なし (none) | Decides on the input and single-file reads only; no child process was launched, even with a live session state. Nothing slow to stop |
| `scan-outbound` | allow-deny hook | あり (with limit) | git and the scanner script, once per staged file |
| `workflow-gate` | allow-deny hook | あり (with limit) | git / gh / bash child processes |
| `enforce-worktree` | allow-deny hook | あり (with limit) | git child processes |
| `confirm-forge-target-ownership` | allow-deny hook | あり (with limit) | gh child processes (its own deadline moves to the shared parts) |
| `check-cross-platform` | allow-deny hook | あり (with limit) | git child processes |
| `block-case-markers` | allow-deny hook | あり (with limit) | git and `bin/check-case-markers.sh` child processes |
| `block-clearance-token-write` | allow-deny hook | あり (with limit) | git, through the workflow session id resolver, for a plans-dir entry nothing else places |
| `supervisor-off-proposal-shim` | allow-deny hook | あり (with limit) | git, through the workflow session id resolver |
| `check-japanese-in-docs` | allow-deny hook | あり (with limit) | git (and a forge query) to tell a private repo |
| `gate-worktree-notes-lang` | allow-deny hook | あり (with limit) | git (and a forge query) to tell a private repo |
| `enforce-system-ops` | allow-deny hook | なし (none) | Pattern match over the command text; no child process, no file scan |
| `block-memory-direct`、`block-history-direct`、`block-shell-config`、`block-tests-direct`、`block-send-user-file` | allow-deny hook | なし (none) | Path and command-text checks plus the session state file; no child process, no file scan |
| `enforce-issue-close`、`block-subagent-sentinels`、`gate-plan-skip-sentinel`、`gate-plan-skill-advance` | allow-deny hook | なし (none) | Command / skill-name match plus the session state file; no child process, no file scan |
| `block-comment-block-size`、`gate-plan-lang` | allow-deny hook | なし (none) | Reads only the content being written; no child process, no file scan |
| `confirm-checkpoint` | allow-deny hook | なし (none) | Denies through `emitDeny`, so it is an allow-deny hook by definition; left out of #2676 by scope (classified only). No child process on the traced paths |
| `rtk-rewrite`、`subagent-dispatch-prompt` | non-allow-deny hook | — | Rewrites the input through `updatedInput` only |
| `show-user-verified-context`、`jev-shadow-pre` | non-allow-deny hook | — | Displays or records only; never a permission decision |

`tests/hooks/feature-2676-hook-classification.js` fails when a registered hook has no row, when a row's classification disagrees with what the hook prints, or when a "あり" row's entry point never arms the limit.
