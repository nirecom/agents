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
| Bulk deletion | Any recursive delete (hook — see below): `rm -r`/`-rf`/`--recursive`, `Remove-Item -Recurse`, `cmd /c rmdir /s` — across spelling, order, and shell, within the coverage noted below. `find -delete` / `find -exec rm` stay glob-denied. |
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
(`hooks/block-credentials.js`, `hooks/block-dotenv.js`,
`hooks/block-recursive-delete.js`) backed by the shared
`hooks/lib/command-parser.js` engine instead of raw glob matching. These hooks
tokenize the command, walk argv, and check only tokens at path-bearing positions —
skipping text-flag values (`--body`, `--title`, `-m`) and `echo`/`printf` positionals.
This prevents false-positives when a protected path appears inside a commit message
or PR body text, while still catching attached-redirect (`>~/.ssh/x`) and
attached-flag (`--file=~/.ssh/x`) bypasses.

`hooks/block-recursive-delete.js` applies the same idea to deletion: instead of
one glob per literal spelling, it judges a single criterion — *does this command
delete recursively?* — over the parsed command, and so also sees the flag
reordered, split, abbreviated, hidden behind one of the ENUMERATED interpreters
(POSIX shells, `pwsh`/`powershell`, and the listed language interpreters —
python, perl, ruby, node, php, lua, awk, tcl, R, osascript, expect), a command
substitution, a newline, or a variable. An interpreter outside that enumeration
is not covered, the same scope qualification the rest of this section carries.
PowerShell's `-EncodedCommand <base64>` payload IS decoded (base64 → UTF-16LE)
and judged like any other inline script body; a payload that cannot be
decoded statically fails closed (block) rather than passing through unscanned.
Mentioning
`rm -rf` in a commit message or issue body still passes. The one sanctioned
route for removing a directory tree is
`node hooks/cleanup-orphan-dir.js --force-if-not-registered <path>`.

Coverage is verb- and shell-specific, and it grows as new bypass classes are
found — `tests/feature-2210-block-recursive-delete/` records the cases currently
covered and the accepted gaps. Deletion verbs other than `rm` / `Remove-Item` /
`rmdir` — `git clean`, `rsync --delete`, `robocopy /MIR` — are not covered by
this hook.

**settings.json carries no recursive-delete glob fallback (fail-open on hook
failure).** Per the single-criterion policy, every `permissions.deny` glob
that used to catch a subset of recursive-delete spellings has been removed
from settings.json — `block-recursive-delete.js` is the SOLE gate now, not a
second layer on top of partial glob coverage. This is a deliberate tradeoff
(duplicating hook-covered ground in settings.json was the thing being
eliminated), but it means a PreToolUse hook error, an uncaught exception, or
a hook that exceeds Claude Code's execution timeout degrades straight to
fully unprotected (approve-by-default) for this whole category, with no
glob-level backstop to catch even the narrow historical spellings. Previously
a hook failure degraded to partial glob coverage; now it degrades to none.

**Known residual gaps (accepted, not silently dropped).** The hook judges
command TEXT with a regex/tokenizer pipeline; it cannot achieve full program
analysis. Specifically out of scope:
- **Dynamic interpreter construction** — building the dangerous call from
  string parts inside an interpreter, e.g.
  `python -c 'import shutil; getattr(shutil, "rm"+"tree")("d")'`. No
  text-level scan can resolve a runtime string concatenation without actually
  executing the interpreter; this is a structural limit of the approach, not
  a bug to be fixed.
- **`xargs` / `eval` / `timeout` indirection** — a delete verb passed through
  one of these as an argument, rather than peeled and re-judged as the
  effective command (`printf 'dir\n' | xargs rm -rf`, `eval "rm -rf dir"`,
  `timeout 5 rm -rf dir`). Currently over-blocked in the conservative
  direction (`tests/feature-2210-block-recursive-delete/cases-posix.sh` still
  documents the old, narrower expectation for these three verbs pending a
  test-file update in a future `/write-tests` pass).
- **Opaque stdin producers** — `echo TEXT | bash` / `printf TEXT | bash` are
  scanned by approximating the producer's stdout from its argv, but an OPAQUE
  producer whose output isn't known from argv alone (`cat file | bash`,
  `curl ... | bash`) cannot be scanned this way; the script content delivered
  over stdin in that shape is invisible to this hook. The old settings.json
  substring glob never caught this shape either, so this is not a regression,
  just an explicitly named limit (see `hooks/lib/bash-write-targets/recursive-delete-scan/stdin-delivery.js`).
- **Bash brace expansion** — `rm -{r,f} dir` expands to `rm -r -f dir` only at
  actual shell runtime; the tokenizer does not simulate brace expansion, so a
  flag hidden this way is not reconstructed (accepted residual gap, see
  `hooks/lib/bash-write-targets/rm.js#dequoteShellToken`).
- **cmd.exe caret escaping** — `cmd /c "r^d /s dir"` uses `^` as cmd.exe's own
  escape character to break up a verb or flag; this hook does not simulate
  cmd.exe's caret-unescaping pass before matching (documented non-goal, see
  `hooks/lib/bash-write-targets/cmd-exe.js`).
- **cmd.exe `%VAR%` immediate expansion — head AND switch position.** cmd.exe
  substitutes `%VAR%` at parse time, before the hook's tokenizer can know what
  it holds, and neither position is fail-closed on it. At the clause HEAD,
  `hasDynamicHead` (`hooks/lib/bash-write-targets/cmd-exe.js`) deliberately
  tests `!VAR!` (delayed expansion) ONLY, so `cmd /c %CMD% /s dir` still
  approves. At SWITCH position, `clauseVerdict` inspects only `/`-leading
  tokens, so a switch delivered whole through a variable —
  `env SW=/s cmd /c "rd %SW% dir"`, a single command line needing no prior
  state — is never examined and also approves. Both are accepted residual
  gaps: closing them means treating every `%VAR%` mention in a cmd.exe payload
  as unresolvable, which over-blocks ordinary `%TEMP%`-style paths.
- **cmd.exe clause-candidate cap.** A launcher clause (`call` / `start` / …)
  is re-judged from every non-switch token onward, capped at
  `MAX_CLAUSE_CANDIDATES` (32) in `hooks/lib/bash-write-targets/cmd-exe.js`.
  A payload that exceeds the cap fails CLOSED — the whole command blocks
  without any candidate being judged — so a long benign launcher line is
  over-blocked by design; the cap exists so a crafted payload cannot make the
  candidate expansion quadratic and time the hook out into fail-open.
- **`/dev/stdin` positional consumers.** The stdin routes recognize a consumer
  that reads its script IMPLICITLY (`... | bash`, `... | python`). A consumer
  handed the pipe as an explicit positional path instead —
  `echo "rm -rf d" | bash /dev/stdin`, `... | python /dev/stdin` (also
  `/proc/self/fd/0`) — parses as "run the script at this path", so the
  producer's text is never judged and the command approves (#2210 C71/C73).
  Not fixed in code this round: the fix needs the positional-path form to be
  folded into `stdinConsumer` without breaking real file arguments.
- **Heredoc bodies.** `python <<EOF ... EOF` and friends ARE now scanned, for
  every heredoc in a command and for delimiters spelled with `.`/`-`
  (`hooks/lib/bash-write-targets/recursive-delete-scan/scan.js#extractHeredocs`).
  Two limits remain: a heredoc whose terminator line never appears is not
  extracted (a shell body still blocks, because the unstripped body lines are
  then scanned as ordinary statements, but a LANGUAGE body — `python <<EOF`
  with no `EOF` — is not), and a second `<<` opener sharing one line with the
  first is not attributed its own body.
- **Cross-process variable correlation** — a flag assembled in one shell
  invocation and consumed by a *different* interpreter body (e.g. a value
  exported into a `pwsh -Command` or `python -c` payload) is not tracked;
  same-shell variable assignment (including split-variable construction like
  `A=-; B=rf; rm $A$B dir`, and assignment on an earlier line of the same
  newline-joined command) is tracked and blocked.
- **`hooks/block-recursive-delete.js`'s output schema** — it still emits the
  older top-level `{"decision": "approve"|"block"}` shape rather than
  `hookSpecificOutput.permissionDecision`. All ten sibling `hooks/block-*.js`
  hooks share this shape and the protected test harness
  (`tests/feature-2210-block-recursive-delete/helpers.sh`) asserts on it by
  design, so migrating it is a cross-file, cross-test-suite change deferred to
  a dedicated session rather than folded into this one.
- **Over-detection on interpreter bodies (precision, not soundness).** The
  single-criterion design ("does this command delete recursively?") is
  deliberately biased toward false positives over false negatives, and two
  places lean on that bias more than strictly necessary: an interpreter
  body containing a bare `$`/`` ` ``/`(` (e.g. `bash -c 'echo $HOME'`) fails
  closed as unresolvable even though a lone `$VAR` reference carries no
  dynamic command construction risk, and a language body is matched against
  the shell-delete shapes with a plain substring/regex scan that cannot tell
  a literal string mention (`python -c 'print("rm -rf d")'`) from an actual
  shell-out call. Both are known, accepted precision limits rather than
  bugs: tightening either risks turning a false positive into a false
  negative, which the user's stated policy (deny everything with a
  recursive flag) treats as the worse of the two outcomes, so this is left
  as a documented limitation rather than "fixed" toward looser matching.

**Known test/implementation mismatches (as of #2210 round 8).** A few assertions
in the protected test files below encode an older, narrower expectation that a
later bypass fix has since closed — the implementation is intentionally the
source of truth in each case, and the test file is left alone (out of
`write-code`'s remit) rather than "fixed" to match the newer, safer behavior:
- `tests/lib/test-recursive-delete-scan.js` still expects `FLAGS=-rf` split
  across a newline from its reference to approve (`out-of-scope` section) —
  this is now blocked (see "Cross-process variable correlation" above).
- `tests/lib/test-recursive-delete-scan.js` also expects PowerShell
  `-EncodedCommand <base64>` to approve — this is a genuine mismatch, not a
  documented non-goal: the implementation decodes the payload and judges it
  like any other pwsh script body, and blocks a `Remove-Item -Recurse`
  payload once decoded (and fails closed on an undecodable one), so the
  test's `out-of-scope` comment is stale.

**The deny list is a speed bump, not a hard wall.** It blocks accidental and reflexive
dangerous commands. Deliberate bypass via shell indirection is a separate threat model
addressed by code review and pre-commit scanning.

### Related

- `docs/scan-outbound.md` — private information scanning (secrets, IPs, blocklist)
- `.private-info-blocklist` — additional per-repo detection patterns (gitignored, private)
