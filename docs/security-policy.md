# Security Policy

## settings.json Permission Model

Claude Code's permission system has three layers: `allow`, `ask`, and `deny`.
Dangerous operations are placed in `deny` so Claude does not execute them on a direct
instruction, an accidental reflex, or the chained-command shapes described below — but,
per "The deny list is a speed bump, not a hard wall" at the end of this document, it is
not proof against deliberate bypass via shell indirection, which is a separate threat model.

### What Is Denied

| Category | Examples |
|---|---|
| Force push (denied) | `git push --force` / `-f`, `+<ref>` refspec, `--delete` / `--prune` / `:<ref>`, `:` matching push, `--mirror`, a lease without `<branch>:<sha>` — `bash-guard` hook (argv parse) + `settings.json` floor rows; `:` refspecs also hit the `origin :*` row |
| Force push (allowed) | `git push --force-with-lease=<branch>:<sha>` only — auto-permitted on feature branches |
| Forced cleanup (denied) | `git clean -f` / `--force`, `git worktree remove -f` / `--force` — `bash-guard` hook + `settings.json` floor rows |
| `.env` direct access | Read/Edit/Write on `.env`, `.env.local`, `.env.production`, etc. |
| Bulk deletion | `rm -rf`, `Remove-Item -Recurse -Force`, `find -delete`, `find -exec rm` |
| AWS destructive ops | `aws * delete`, `aws * terminate`, `aws * destroy`, `aws s3 rm`, etc. |
| Git history rewrite | `git reset --hard`, `git commit --amend`, `--no-verify`, `git branch -D` |
| Pipe-to-shell | `curl | bash`, `wget | sh`, etc. |
| Credential files | `~/.ssh/` (hook — see below), `~/.aws/`, `~/.gnupg/`, `~/.docker/config.json`, etc. |
| Shell init files | `~/.bashrc`, `~/.zshrc`, `~/.profile`, etc. |
| `history.md` | Edit/Write to any `**/history.md` (append-only via `doc-append` CLI) |

### Design Considerations

**Glob matching is text-based.** Rules match against the raw shell command string.
MUST-trigger git rules are anchored to the START of a real git-invocation form (bare `git`,
`git -C *`, `git -c *`, `git --no-pager`) — see `docs/architecture/claude-code/settings.md`
"Permission glob matching" for the full anchoring contract and the #2280 incident that
anchoring fixes. This means:
- `*` spans spaces and matches the empty string, so a glob cannot tell an `-f` flag from an
  `-f` inside a branch name (#2617: `git push *-f*` denied `feature/…` pushes and the lease
  form). Argument-position judgment therefore lives in `bash-guard`'s git-deviant detector;
  settings.json keeps only position-safe floor rows (`git push --force *`, `git push -f*`, `git push *-f`, …)
- Only the explicit lease `--force-with-lease=<branch>:<sha>` is allowed; a lease without a
  value, or with a non-40-hex sha, is denied by the hook
- Interior `*` in a deny glob (e.g. `git push *--force`) is a deliberate widening so that
  `git push origin branch --force` — remote/refspec args between the subcommand and the flag
  — still matches; the failure direction is toward more caution, never a bypass
- Commands built through variables, aliases, or shell expansion are not reliably caught

**Known residual gaps (accepted, #2280).** The 4 launch-form prefixes enumerate a bounded
set — an unmatched form falls through to the interactive "ask" prompt, never to silent
auto-approval, so this is a coverage gap, not a bypass. OPTIONAL categories (rm, find,
sudo, docker, aws) retain their leading `*` because the threat in those cases is in the
argument position, not the invocation form; changing them to anchored forms would not
improve coverage.

**Compound-command bypass is closed by `bash-guard.js`'s unconditional deny.**
`permissions.allow` globs match the WHOLE command string, so a broad allow rule like
`Bash(cd * && git commit *)` would blanket-forgive any destruction appended after the
commit (e.g. `cd /repo && git commit -m x && git push --force`). `bash-guard.js` denies
any compound form containing `&&`/`;`/`|`/backtick/`$(…)`/redirect/leading-env-prefix
unconditionally — before the permission engine evaluates the string — so the whole-string
allow never reaches a compound command. The primary settings.json anchoring layer remains
authoritative for standalone invocations.

**Hook-based protection is context-aware.** Some rules use a PreToolUse hook
(`hooks/block-credentials.js`, `hooks/block-dotenv.js`) backed by the shared
`hooks/lib/command-parser.js` engine instead of raw glob matching. That engine choice
is deliberately retained even though the command IR moved to a new parser — see
`docs/architecture/claude-code/shell-command-parsing.md` for the ownership map and the
migration order. These hooks tokenize the command, walk argv, and check only tokens at
path-bearing positions — skipping text-flag values (`--body`, `--title`, `-m`) and
`echo`/`printf` positionals. This prevents false-positives when a protected path appears
inside a commit message or PR body text, while still catching attached-redirect
(`>~/.ssh/x`) and attached-flag (`--file=~/.ssh/x`) bypasses.

**The deny list is a speed bump, not a hard wall.** It blocks accidental and reflexive
dangerous commands. Deliberate bypass via shell indirection is a separate threat model
addressed by code review and pre-commit scanning.

### Related

- `docs/scan-outbound.md` — private information scanning (secrets, IPs, blocklist)
- `.private-info-blocklist` — additional per-repo detection patterns (gitignored, private)
