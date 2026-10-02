# bash-guard Hook Contract

Full behavior contract of `hooks/bash-guard.js`; the hook table and every other hook live in [hooks.md](hooks.md).

- `bash-guard.js` (PreToolUse, matcher: `Bash`) — classifies each Bash command into one of
  four verdicts, in priority order: **deny** → **notify** → **allow** → **passThrough**.
  **Matcher is bare `Bash`**, unlike most hooks in this table (`Bash|runInTerminal|runCommands`)
  — `runInTerminal`/`runCommands` can drive pwsh, where a backtick is a line continuation and
  `{ }` a script block, so reading that with a bash parser would produce confident false denials;
  those tools are deliberately out of scope (a documented hole, see "Known limitations" in [settings.md](../settings.md)), not an
  oversight. Detection parses via the shared command IR (`hooks/lib/command-ir`), never a regex
  over raw text.
  - **deny**: forbidden compound-shell literal (`&&`/`;`, `|`, backtick/`$(...)`, `{ ... }`,
    `<<`, `>`/`>>`, leading `FOO=1 cmd` env-prefix) per `rules/shell-commands.md`.
    A pipe into `xargs` is forgiven at that hit only (xargs-pipe exemption in
    `hooks/bash-guard/detect.js`). Output: `{decision:"block", reason}`.
  - **notify** (non-blocking): ineffective issuance form detected. Three classes —
    L1 sentinel without `echo`, L2 sentinel in wrong form (unknown or LOOKSLIKE-only pattern;
    LOOKSLIKE forms are left to `workflow-mark.js`'s existing handlers to avoid double-notification),
    L3 script path without interpreter prefix. Output: `{systemMessage: msg}`.
    Reason codes: `BG-NOTIFY-SENTINEL-NO-ECHO` / `BG-NOTIFY-SENTINEL-UNRECOGNIZED` / `BG-NOTIFY-SCRIPT-NO-INTERPRETER`.
  - **allow**: command is an agents-own script from `install/settings-allow-commands.txt` or a
    bare name from `install/path-exposed-commands.txt`. IR-normalizes cwd and path to check
    against both lists via `hooks/lib/allow-command-list.js` (agents root or a linked worktree;
    single-quoted `bash -c` re-judged once — see [settings.md](../settings.md) "Self-script allow
    in bash-guard"). Repo-relative forms need an absolute `cwd`, else passThrough.
    Output: `{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow",
    permissionDecisionReason:"bash-guard BG-ALLOW-*"}}`.
    Reason codes: `BG-ALLOW-SELF-SCRIPT` / `BG-ALLOW-SELF-BARE`. A plain external read-only
    command (class list `install/readonly-command-classes.json`, judged by
    `hooks/bash-guard/readonly-class.js`) also allows, with `BG-ALLOW-READONLY-GIT` /
    `BG-ALLOW-READONLY-GH` / `BG-ALLOW-READONLY-GENERIC` — see `settings.md`. A newline or CR
    in the command skips every allow.
  - **passThrough**: no verdict to report; silent exit 0, normal permission flow continues.
    Reason codes: `BG-TOOL-OUT-OF-SCOPE` / `BG-INTERLOCK-QUIET` / `BG-PARSE-FAILURE` / `BG-NO-HIT`.
  Reason-code namespace is disjoint from workflow-gate's `T-A..T-E` tiers.
  **Interlock (C6)**: stays quiet while the early-write gate is actually blocking
  (`hooks/lib/early-write-gate.js` `earlyWriteGateStatus(sessionId).active`), so the two
  guards never talk over each other. One exception: when deny and notify both find nothing,
  a read-only class match still allows (the gate blocks Edit/Write, not Bash reads) — see
  `marker-bypass-contract.md`, which also records
  that this hook is never bypassed by `WORKFLOW_OFF`/`WORKTREE_OFF`.
  **Stdin**: unreadable stdin → deny; malformed JSON → no stdout, one stderr diagnostic line
  (see [hook-stdin-input.md](../hook-stdin-input.md)). `judgeBashCommand` throw → no output.
  `parse()` failure → passThrough.
