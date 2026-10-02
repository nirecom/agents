# Hook Stdin Input Contract

How hooks and the bin tools on a hook's inspection path read their stdin, and what each hook class does when that read fails. This file is the SSOT for hook stdin handling; per-hook contracts in [settings/hooks.md](settings/hooks.md) reference it.

## Why one shared reader

Hooks used to copy a private `readStdin` that reused one fixed buffer and kept `buf.slice(0, n)` views of it. A slice aliases the buffer, so every input longer than the buffer was overwritten by the next read, `JSON.parse` failed, and most hooks approved. Large Write/Bash inputs therefore passed security hooks unchecked and state-recording hooks silently dropped their record (#1810, #2479). `bin/scan-offensive`, which `scan-outbound.js` runs on outbound content, carried the same defect and also swallowed read errors.

## Reader

`hooks/lib/read-stdin.js` is the only sanctioned stdin reader. It loops on fd 0 with a 64 KiB buffer and copies every chunk out of it. EOF ends the read; `EAGAIN` / `EINTR` are retried with a 1 ms wait, and `EAGAIN` is bounded by a 5000 ms wall-clock budget of consecutive unreadable time (each successful read restarts it). It never prints and never exits: the caller decides fail-open vs fail-close.

`readHookInput()` returns one of three states:

| State | Meaning |
|---|---|
| `ok` | Input read and parsed (`input`, `text`) |
| `read-error` | The read itself failed (`error`, e.g. `EBADF`, or `EAGAIN` past the budget) |
| `json-invalid` | Read succeeded but the text is empty, whitespace, or not JSON (`workflow-gate.js` and `enforce-worktree.js` also treat valid JSON that is not an object, such as `null`, this way) |

`readStdinText()` returns `ok` / `read-error` only, for tools that read plain text.

## Failure policy by class

The two failure states are kept apart because they mean different things: `json-invalid` is a malformed but observed payload, so each hook keeps its historical verdict; `read-error` means the hook cannot see the payload at all.

- **Security guards** (block-dotenv, block-credentials, bash-guard, enforce-system-ops, scan-outbound, ...): `read-error` fails closed with `readFailureReason()` as the block reason (or exit 2 stderr). An unreadable input must never be mistaken for a harmless one.
- **Commit and worktree gates**: `workflow-gate.js` blocks on both states. `enforce-worktree.js` blocks on `read-error` only after its own escape hatches: `ENFORCE_WORKTREE=off`, then the session's WORKFLOW_OFF / WORKTREE_OFF markers (session id from the environment, since there is no input).
- **Deliberate fail-open exceptions**: `scan-inbound.js` and `confirm-forge-target-ownership` stay fail-open on `read-error`.
- **Inline-body scope**: `enforce-system-ops.js` rescans interpreter bodies of POSIX shells, `eval`, and `pwsh -c` / `-Command` only — not `cmd /c`, `python -c`, `node -e`, or abbreviated pwsh parameters. A body set past the scan cap, an interpreter body still nested past the recursion cap, or a classifier error, fails closed (exit 2). A line the IR cannot parse is also rescanned with the pre-IR quoted-body regex.
  - Known limit: the IR tokenizer does not decode backslash escapes outside quotes, so the `'\''` idiom can mis-tokenize a body nested two levels deep.
  - Known limit: pwsh abbreviations (`-Comm`, `-command:x`, `/Command`), a positional `powershell.exe` body, and `-EncodedCommand` are not extracted.
- **Env bypass first**: `enforce-system-ops.js` evaluates `SYSTEM_OPS_APPROVED=1` before reading, so the bypass still works when stdin is unreadable.
- **Permission and rewrite hooks** (preuse-auto-approve, gate-plan-skip-sentinel, rtk-rewrite): abstain on both states; abstaining is their default path.
- **State-recording, Stop, and display/inject hooks**: fail open on both states, so a broken read never wedges a session.
- **`bin/scan-offensive`**: `read-error` exits 3, which `scan-outbound.js` already treats as block.

## Fail-open diagnostics

A fail-open branch that skips a check or a persistent record writes exactly one stderr line from `readFailOpenDiagnostic(hook, result, effect)`, for example `[workflow-mark] stdin read-error (EBADF): step mark not recorded (fail-open)`. The line carries the byte count and error code only, never the payload. It is written only on exit-0 paths, where Claude Code does not interpret stderr as the hook's response.

No diagnostic is written by fail-closed branches (the reason already says it), by abstaining hooks, or by display/inject-only hooks. A display-dedup marker is not a persistent record.

## Static check

The `lint-*` cases in `tests/hooks/unit-read-stdin.sh` forbid a private fd-0 read (`readSync(0, ...)`, `readFileSync(0)`, `/dev/stdin`, `process.stdin.fd`) in every `hooks/**/*.js` except the reader, and in every file under `bin/**` regardless of extension. Comments are scanned too, so prose describing the old pattern must not spell it out. Out-of-scope bin readers are listed by name in the test's exclusion table, and a row that stops matching fails as a stale exception.

Behavior is pinned by `tests/hooks/unit-read-stdin.sh` (reader), `tests/hooks/stdin-large-input-hooks.sh` (inputs past 4096 / 65536 bytes), and `tests/hooks/stdin-read-failure-policy.sh` (injected `EBADF` per class).
