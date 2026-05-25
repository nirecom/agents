# Security Policy

## settings.json Permission Model

Claude Code's permission system has three layers: `allow`, `ask`, and `deny`.
Dangerous operations are placed in `deny` so Claude cannot execute them even if instructed.

### What Is Denied

| Category | Examples |
|---|---|
| Force push (denied) | `git push --force`, `git push -f`, `+<ref>` refspec form |
| Force push (allowed) | `git push --force-with-lease` — auto-permitted on feature branches |
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
This means:
- `*push --force` / `*push --force *` / `*push *--force` / `*push *--force *` catch bare `--force` at end-of-command or before a space — the `-with-lease` suffix prevents any match against `--force-with-lease`
- `*push -f*` / `*push *-f` / `*push *-f *` catch bare `-f`; `-f ` (dash-f-space) is not a substring of `--force-with-lease`
- `*push *+*` catches `+<ref>` force-push refspec syntax
- Commands built through variables, aliases, or shell expansion are not reliably caught

**Hook-based protection is context-aware.** Some rules use a PreToolUse hook
(`hooks/block-credentials.js`, `hooks/block-dotenv.js`) backed by the shared
`hooks/lib/command-parser.js` engine instead of raw glob matching. These hooks
tokenize the command, walk argv, and check only tokens at path-bearing positions —
skipping text-flag values (`--body`, `--title`, `-m`) and `echo`/`printf` positionals.
This prevents false-positives when a protected path appears inside a commit message
or PR body text, while still catching attached-redirect (`>~/.ssh/x`) and
attached-flag (`--file=~/.ssh/x`) bypasses.

**The deny list is a speed bump, not a hard wall.** It blocks accidental and reflexive
dangerous commands. Deliberate bypass via shell indirection is a separate threat model
addressed by code review and pre-commit scanning.

### Related

- `docs/scan-outbound.md` — private information scanning (secrets, IPs, blocklist)
- `.private-info-blocklist` — additional per-repo detection patterns (gitignored, private)
