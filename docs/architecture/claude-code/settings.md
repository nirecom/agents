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
defense is segment-aware, one layer up: `hooks/bash-guard/exemptions.js`'s
`anySegmentDenyMatched()` (backed by `isDenyRuleMatch` in `hooks/lib/settings-allow-match.js`)
withholds the allow-rule-match exemption when ANY individual segment's own text matches an
anchored deny rule, forcing the model to resubmit the command as separate Bash calls — each of
which then hits the anchored deny rule directly. Only interactive approval ("Yes, don't ask
again") splits subcommands and saves individual rules (a third, separate mechanism).

`hooks/lib/settings-allow-match.js` reads this semantics as its SSOT to decide whether an
existing `permissions.allow` rule already covers a `bash-guard.js` candidate — it is an
**approximation of the host's own permission matcher, not a reimplementation**. Its bias is
deliberately one-directional: over-matching only silences a presentation guard (harmless —
the command was already permission-granted), while under-matching would deny a command the
user explicitly allowed (harmful), so every ambiguity — an unreadable or unparsable
`settings.json` included — resolves to the wider side (treated as a match).

**Generated allow rules for agents' own commands**: because a rule matches the whole command
string, one internal command issued two ways needs two rules, and hand maintenance cannot track
that. The fact "this command is an allow-target" therefore has exactly one owner and the rule
strings are generated from it.

- Dataflow: `install/settings-allow-commands.txt` (the SSOT — command paths only) → `install/gen-settings-allow.js` (the CLI) → `install/lib/settings-allow-rules.js` (expansion) → merged over the repository's `settings.json` by `install/lib/settings-assembly.js` → the deployed file. Never hand-edit a generated rule.
- The expanded rules are injected into the deployed `~/.claude/settings.json` at deploy time; that deployed document is the only place an operator reads them back.
- They are therefore never committed: the tracked `settings.json` in this repo carries hand-written rules only, so a generated rule found there is a leftover from before this design, not a source.
- `install/lib/settings-allow-rules.js` owns the spelling template table — the one place it exists; the CLI, the assembler and the drift check all read it from there rather than restating it.
- Twenty-four path spellings are emitted per command, plus six bare spellings when `install/path-exposed-commands.txt` gives that command's basename a PATH shim — thirty rules for a PATH-exposed command. The interpreter comes from the command's own shebang, and anything but bash or node stops the generator.
- Each template is emitted as a pair: an argument-bearing form and an argument-less twin as well.
- The pair exists because the permission engine matches the whole command string, not a prefix — a trailing ` *` demands the space before it, so it never covers the argument-less invocation.
- `install/assemble-settings.js` is the sole deploy entry point and `install/lib/settings-deploy.js` its single writer, so any other code writing that file is a bug. The deploy is fail-closed: when the rules cannot be expanded, nothing is written and the previous deployment stands.
- Admitted: auto-issued, repo-state-invariant, idempotent internal tools. Excluded on principle: `gh` writes, git state changes, `.env` readers, platform-launched hook bodies, wrapper launchers such as `bin/run-with-timeout.sh` whose trailing ` *` template would allow-list every command reachable through them, and dispatchers that reach a state-changing or credential-reading operation through an argument or subcommand the permission engine never sees (e.g. a worker-dispatch script whose outer invocation is the only thing matched).
- Orphan detection is the known limit of the design: `--check` reports a generated-shaped rule whose command has left the SSOT, but the deploy appends only and never removes one, because removal is a manual judgment made by hand. A bare-form rule is only claimed when the generator emits bare rules for this tree at all, its name carries a separator and no command of that name is left under `bin/`, so a dropped command whose file still exists goes unreported.
- An allow rule only removes the permission prompt; it does not disarm a PreToolUse hook. `bin/review-code-codex` is allow-listed and still sends a diff outbound under `hooks/scan-outbound.js`.
- Nothing in the commit path guards these rules any more, and nothing needs to: a hand-maintained mirror is what could drift, and there is no longer one. `hooks/session-start.js` reports a deployed document that has fallen behind, and `hooks/post-merge` / `hooks/post-checkout` re-deploy when the SSOT, either list, or any of the four modules changes.
- `install/settings-allow-commands.txt` entries must be plain repo-relative paths — no `..`, leading slash, drive letter, backslash, glob, or shell metacharacter — because each entry is interpolated into twenty-four path permission rules, plus six more bare rules when `install/path-exposed-commands.txt` gives it a PATH shim, where a metacharacter widens a rule instead of naming a file. `install/gen-settings-allow.js` itself is deliberately absent from its own SSOT: it is run by hand, never auto-issued mid-session, so listing it would buy no coverage.
- Prompt assets write an SSOT-listed command path in one of two spellings, and the spelling alone decides whether the text is a command line: a command line to be run keeps `bash` or `node` in execution position with the entry path in argument position (`bash "$AGENTS_CONFIG_DIR/bin/foo"`), while a citation that only names where the file lives drops the `$AGENTS_CONFIG_DIR/` prefix and is written repo-relative (`bin/foo`). The two are otherwise structurally identical — `Run: ` and `Backend script path: ` in front of the same backtick span differ only by an English label — so the prefix, not the surrounding prose, is what `tests/prompt-bash-node-calling-convention/` reads to separate a command from a citation, which keeps that check deterministic instead of dependent on a vocabulary of label words.

**Known limitations**:
- TL3 verification gap: `tests/feature-2119-settings-allow-ssot/` proves the generated rule
  strings match the template contract exactly, never that Claude Code's own permission matcher
  honors a given spelling live — that engine is the product's closed runtime, outside this repo's
  test reach. Confidence rests on the #2201 root-cause measurement (94.7% ask rate for
  `resolve-worktree-path` across 482 real transcripts, resolved once the missing quoted-absolute
  template was the one variable changed), not on an executable assertion. That fix covers only the
  rule-generation side for an already argument-position command string — it does not reach a
  command whose leading token is itself an unexpanded shell variable (execution-position, e.g.
  `"$AGENTS_CONFIG_DIR/bin/foo"`), which the matcher never treats as a static path and always
  "ask"s regardless of template; #2262's later transcript measurement found 820 of 8,237
  `$AGENTS_CONFIG_DIR`-bearing Bash calls (10%, 560 sessions) still in that form, fixed by rewriting
  the prompt-asset command literals to the argument-position `bash <path>` form. A human confirming a
  real quoted-absolute-path invocation stops prompting against a live deployed settings.json is
  the final check for any future template addition, not something CI can close out.
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
