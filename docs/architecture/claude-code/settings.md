# settings.json Design

**Allow rules** — read-only operations only:
- Git read commands (`git status`, `git log`, `git diff`, `git branch`, etc.)
- `git -C <path>` for cross-directory git reads — preferred method
- Filesystem reads (`ls`, `tree`, `head`, `tail`, `grep`, `wc`, etc.)
- `.env.example` reads (`.env` itself is denied)

**Deny rules** — four categories (wildcard prefix `*` to catch compound commands):

| Category | Target |
|:---|:---|
| Environment files | `.env`, `.env.*` |
| Destructive commands | Force push, hard reset, deletion |
| Credentials | SSH, GPG, AWS, Azure, gh, git, Docker, kube, npm, PyPI, gem, netrc, pgpass, MySQL, curl, Maven, Gradle, Terraform |
| Direct dotfile editing | Home directory dotfiles |

See `docs/security-policy.md` for the full pattern list.

**Hook format**: Nested format — `matcher` + `hooks` array. Timeout in seconds.

```json
{ "matcher": "Edit|Write", "hooks": [{ "type": "command", "command": "node .../hook.js", "timeout": 5 }] }
```

**Hooks**: the full per-hook behavior contracts live in [settings/hooks.md](settings/hooks.md) — PreToolUse guards (outbound + credential/dotenv scanning, `workflow-gate.js`, `bash-guard.js`, `enforce-worktree.js`, `rtk-rewrite.js`, cross-platform and forge-target checks), PostToolUse marks and language backstops (`workflow-mark.js`, `workflow-run-tests.js`, plan/notes language checkers), Stop guards (`stop-final-report-guard.js`, `stop-confirm-plan-guard.js`), and the SessionStart / UserPromptSubmit injectors. See that file for matchers, fail-open/closed semantics, and marker-bypass behavior.

**Permission glob matching**: Permissions are matched against the entire command string.
`&&` does not split into subcommands, so `Bash(git commit *)` does not match
`cd /path && git commit -m msg` (starts with `cd`). MUST-trigger deny rules are anchored to
the START of a real git-invocation form — bare `git`, `git -C *`, `git -c *`,
`git --no-pager` (#2280: a leading `*`, e.g. `*git commit --amend*`, matched the substring
ANYWHERE in the string and false-positived on a sentinel that only NARRATED a force push,
auto-denying it). The OPTIONAL rm/find/sudo/docker/aws family keeps its leading `*` on
purpose — a `sudo`/`env`/`xargs` prefix breaks the first-token guarantee anchoring depends on.
Anchoring means a `cd /path && git commit --amend -m x` compound is deliberately NOT caught
at this settings.json level — no anchored rule spans the `cd &&` prefix. That shape's real
defense is `bash-guard.js`, which issues an unconditional deny for any compound form containing `&&`/`;`/`|`/backtick/`$(…)`/redirect/leading-env-prefix — the forbidden-literal check fires before the
permission engine ever evaluates the command string. Only interactive approval ("Yes, don't ask
again") saves individual rules for a given pattern.

**Self-script allow in bash-guard**: agents' own commands bypass the permission prompt via
`bash-guard.js`'s allow path — no generated `permissions.allow` spellings needed.

- Dataflow: `install/settings-allow-commands.txt` (command paths, one per line) + `install/path-exposed-commands.txt` (PATH-shim basenames) → `hooks/lib/allow-command-list.js` (loads + validates both lists) → `hooks/bash-guard/allow.js` `matchSelfScript()` (IR-normalizes the incoming command and compares) → verdict `allow` → `hooks/bash-guard.js` emits `{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", permissionDecisionReason:"bash-guard BG-ALLOW-*"}}`.
- IR normalization strips `$AGENTS_CONFIG_DIR/` and `${AGENTS_CONFIG_DIR}/` prefixes, resolves the agents-repo absolute path (POSIX, Windows, and MSYS `/c/…` forms), and accepts a repo-relative path only when `tool_input.cwd` (falling back to `input.cwd`) resolves to the agents root. When `cwd` is absent, not a string, or not absolute, repo-relative forms are NOT allowed — the command falls through to `passThrough` (fail-open toward the permission prompt, never toward allow).
- Hook allow does not override `permissions.deny` or `permissions.ask` rules. Claude Code evaluates those rules regardless of what a PreToolUse hook returns.
- `install/settings-allow-commands.txt` entries must be plain repo-relative paths — no `..`, leading slash, drive letter, backslash, glob, or shell metacharacter.
- Prompt assets that invoke an SSOT-listed command keep `bash` or `node` in execution position with the entry path in argument position (`bash "$AGENTS_CONFIG_DIR/bin/foo"`); a citation that only names where the file lives uses the bare repo-relative form (`bin/foo`). The prefix distinguishes invocation from citation without requiring a vocabulary of surrounding prose labels.
- Not admitted to `install/settings-allow-commands.txt` (deliberate exclusions): `run-with-timeout` wrappers are not repo scripts and are excluded; gh writes are excluded; git state-changing commands are excluded; hook bodies are excluded (not issued through the permission engine); worker dispatchers are excluded (state-changing work hides behind arguments).
- `install/assemble-settings.js` is the only writer of the deployed `settings.json`; treat a second writer as a bug.

**Known limitations**:
- TL3 verification gap: `tests/hooks/TL3-hook-bash-guard-envelope.sh` (gated by `RUN_TL3=on`) probes
  three claims about bash-guard's live behavior — (a) that `systemMessage` / `additionalContext` reach
  the model, (b) that `passThrough` (silent exit 0) and the legacy `{decision:"approve"}` output are
  equivalent in Claude Code's permission engine, and (c) that a companion hook's `{decision:"block"}`
  prevails over bash-guard's `permissionDecision:"allow"`. Research findings
  `[hook-silent-exit0]` and `[hook-allow-respects-rules]` are the current evidence base for (b) and (c)
  respectively; the first covers the silent-exit case, the second covers settings.json deny/ask
  priority over hook allow. Hook-to-hook composition (whether one hook's allow is overridden by another
  hook's block) is not explicitly documented by the product. `RUN_TL3=off` (the default in `.env`)
  skips the live-environment probes; a developer setting `RUN_TL3=on` activates them.
- PreToolUse hook on Edit|Write bypasses the "Ask before edits" dialog (hook success =
  permission granted). Delegate Edit|Write scanning to the pre-commit hook.
- Hook format must be nested. Flat format (matcher/command/timeout at the same level) causes
  the entire settings.json to be skipped.
- VSCode's "Ask before edits" mode covers Edit/Write only — Bash commands do not trigger
  the ask dialog.
- Hot-reloading of settings.json hook changes is unreliable. Restart Claude Code after changes.
- `bash-guard.js`'s matcher is `Bash` only (see [settings/hooks.md](settings/hooks.md)) — a compound command issued through
  `runInTerminal` / `runCommands` (VS Code-integrated terminal tools) never reaches it and
  is not otherwise denied. Parsing pwsh with a bash-syntax parser is worse than not parsing
  it at all (backtick = continuation not command-substitution, `{ }` = script block not
  grouping, `$env:` = a different variable form), so covering those tools is deliberately
  out of scope rather than attempted with a parser that would misjudge them. This is a known
  gap, tracked for a follow-up issue rather than closed here.

## AWS Permission Posture

Claude Code operates with read-only AWS access during scan skills. Recommended IAM grants:
- `ec2:Describe*`, `s3:ListAllMyBuckets`, `s3:ListBucket`, `s3:GetBucketAcl`, `s3:GetBucketPolicyStatus`
- `iam:List*`, `iam:Get*` (not Create/Put/Attach/Delete)
- `ce:GetCostAndUsage`, `ce:GetCostForecast`
- `ecs:List*`, `ecs:Describe*`, `lambda:List*`, `lambda:Get*`
- `elasticloadbalancing:Describe*`, `apigateway:GET`, `apigatewayv2:GET`, `cloudfront:List*`, `cloudfront:Get*`
- `cloudtrail:Describe*`, `cloudtrail:Get*`, `guardduty:List*`, `guardduty:Get*`, `config:Describe*`, `securityhub:Describe*`
- Explicit deny: `*:Delete*`, `*:Remove*`, `*:Terminate*`, `*:Put*`

`settings.json` deny/ask rules are defense-in-depth. Server-side IAM is the authoritative layer.
IAM policy setup is tracked in `docs/todo.md`.
