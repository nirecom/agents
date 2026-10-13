# Plan Sync

Publishes each final session plan (`<sid>-intent.md`, `-outline.md`, `-detail.md`) to a
private git remote so the plan can be read from the iOS/Android Claude apps or any
browser, not only from the machine that wrote it (#2513).

## Why

The plan confirmation steps (`CONFIRM_INTENT` / `CONFIRM_OUTLINE` / `CONFIRM_DETAIL`)
ask the user to read a plan before approving it. A bare local path is useless away from
the desktop. The earlier answer was to auto-open the file in a VS Code window; that
needed a VS Code session on the same machine and was removed. A forge blob URL works on
every device that can sign in to the forge, so the model writes that URL in its response
text, where the iOS/Android Remote Control apps show it (a hook `systemMessage` is shown
on the PC only).

A plan carries the design of the project it was written for, so it is sent only to a
remote on the same host as that project: a plan for a project hosted on one forge never
reaches a plan remote on another.

Plan sync is a sibling of [session-sync](session-sync.md) and uses the same remote-URL
format, but it is a different mechanism: session-sync moves whole session history on
demand; plan-sync publishes the existing plans once at init, then pushes one plan file
at the moment it is written.

## Setup

1. Create an empty **private** repository yourself — no README needed — or let the
   interactive setup create it (below). Init pushes the first commit to the empty repo.
2. Set it in `agents/.env` (gitignored; template in `.env.example`):

   ```
   PLAN_SYNC_REMOTE_URL=git@<forge-host>:YOUR_USERNAME/agent-plans.git
   ```

   GitHub or GitLab (github.com or a self-hosted GitLab declared by `GITLAB_HOSTNAME` /
   `GITLAB_SSH_HOSTNAME`). SSH or HTTPS both work. HTTPS needs credentials that never prompt
   (Git Credential Manager, `gh auth setup-git`); never put a token inside the URL. Empty
   (the default) turns plan sync off; the plan link carries the local path only.
   Pick an HTTP(S) URL when the forge's web side is plain `http` or on a non-default port:
   an SSH URL's blob link always uses `https` on the default port.
3. Provision once with `bin/plan-sync-init` (Windows wrapper
   `install/win/plan-sync-init.ps1`; `install.sh` / `install.ps1` call it too). It is
   idempotent and safe to re-run, and must be re-run after changing the URL.

**Interactive setup.** When `PLAN_SYNC_REMOTE_URL` is empty or still the `.env.example`
placeholder, no `--remote-url` is given, and stdin is a TTY, init asks instead of stopping
(`hooks/lib/plan-sync/init-interactive.js`):

- **GitHub** (empty value, or a GitHub placeholder): `gh` supplies the signed-in login and
  proposes `<login>/agent-plans`.
- **GitLab** (a GitLab placeholder such as `git@<gitlab-host>:YOUR_USERNAME/agent-plans.git`):
  `glab api --hostname <web host>` supplies the username, which fills `YOUR_USERNAME`; the
  template's own host and form are kept.

An existing private repo is offered for reuse, a public or internal one aborts, and an
absent one is created private after a y/N prompt (GitLab reads the visibility back after
creating, since an instance policy can override it). Init then provisions and asks y/N
before writing `PLAN_SYNC_REMOTE_URL` into the agents `.env` (temp file + rename, file mode
kept, every existing line replaced). A missing or signed-out `gh` / `glab` prints how to
fix it and exits 0 as "not configured". Non-interactive runs behave as before.

**Export precedence.** An exported `PLAN_SYNC_REMOTE_URL` outranks `.env`. Init says so at
the start, still provisions, and exits 1 even after writing `.env`, because the hooks keep
reading the exported value until the export is removed.

`PLAN_SYNC_REMOTE_URL` is on the `.env.local` overlay blocklist (see
[local-env-overrides.md](local-env-overrides.md)): a project must not redirect where
every plan is published. Plan sync's forge settings (`GITLAB_HOSTNAME`, `GITLAB_SSH_HOSTNAME`) are
read from the agents configuration only, never from a project's `.env.local`.
`--remote-url` on the init CLI overrides the hook-resolved value; because the hook keeps
reading env then `.env`, init warns after success when the two differ.

## How it works

Two phases with different costs.

**Provision (once, `bin/plan-sync-init`).** Turns the plans directory
(`PLANS_DIR`, `~/.workflow-plans/` by default) into a git working tree: `git init`,
`HEAD` pointed at `main`, hooks/fsmonitor/autocrlf neutralised, `origin` set, the
allowlist `.gitignore` written, and the local plans converged with the remote. Every plan
file already in the plans directory that passes the send rule (below) is published in the
same commit, so plans written before sync was set up reach the remote too. A name the
remote already holds is never overwritten, and re-running init publishes only the plans
the remote lacks. A local `main` entry is carried only while the file on disk still holds
exactly that content. The init version is recorded in local git config. Visibility is
checked here (see below).

**Send rule (project-host record).** When a plan is written, the host of the project it
was written for is recorded beside it as `<sid>-note-project-host-<stage>.json`. The
project is the hook input's `cwd` alone — never `CLAUDE_PROJECT_DIR`, the process cwd or
the session state, which may name another project; a hook input without `cwd` records "no
host". The host comes from every URL `git remote get-url --all origin` returns there
(`insteadOf` applied); no repository, no origin, or URLs on different hosts record "no
host". The record keeps the web host (plus scheme and port for HTTP(S)), never the origin
URL. Three states follow:

| Record | Sent | Plan link |
|---|---|---|
| host equals the destination's host | yes | blob URL plus local path |
| another host (`host-mismatch`) | no | local path, model only |
| no host (`no-project-host`) | no | local path, model only |

A missing or malformed record is never a match. Hosts compare by web host (an SSH alias
such as `ssh.github.com` or `GITLAB_SSH_HOSTNAME` maps to it); when both sides are HTTP(S)
the scheme and effective port must match too, while an SSH port is never compared. An
alias defined only in an SSH config file is not resolved, so it counts as another host.
The same rule gates provisioning, per-write sync and the carried local entries. A plan
held back stays in the plans directory and shows up there as an untracked file.

**Sync (every plan write).** `hooks/show-plan-link.js` (PostToolUse) calls
`syncPlanFile` synchronously after a final plan artifact is written — by any edit-write
tool (Write, Edit, MultiEdit, editFiles, NotebookEdit; class SSOT
`hooks/lib/write-tools.js`) or by an `assemble-mandatory.sh` command. All plan files
written by one tool call share a single 20-second budget inside the 30-second hook
timeout. It proceeds only
when `checkProvisioned` passes: a network-free check that the repo exists, the recorded
init version matches, `origin` equals the configured URL and passes the URL allowlist,
no `insteadOf` / `pushurl` rewrite applies, and the `.gitignore` is byte-identical to
the rendered allowlist. Anything else yields a `not-provisioned` result naming the
reason, with a hint to run `bin/plan-sync-init`.

- **Allowlist.** The `.gitignore` ignores everything except `*-intent.md`,
  `*-outline.md`, `*-detail.md`. Surveys, review logs and other artifacts never leave the
  machine, and the publish step re-filters by file name independently of the ignore file.
- **Commit and push.** Commits are built with git plumbing, not the working index: the
  plan blob is overlaid on the remote tip (`origin/main`) together with allowlisted
  local-only entries, `refs/heads/main` is advanced with a compare-and-swap, and the
  result is pushed with `--no-verify` under a fixed identity (`plan-sync@localhost`).
  Local `main` is never pushed as-is. A non-fast-forward fetches the tip and rebuilds, up
  to a small retry cap, inside a wall-clock budget. A "nothing to publish" result is
  trusted only after that attempt fetched the tip, so a stale `origin/main` cannot hide a
  revision that never reached the remote. Remote content is only ever added or
  overwritten, never deleted.
- **Plan link for the model.** `show-plan-link.js` (after a write) and
  `confirm-checkpoint.js` (before a CONFIRM) hand the model one `[plan-link]` line per plan
  as `additionalContext`: `<stage>: <blob URL> (<local path>)` when published, otherwise
  `<stage>: <local path> (no URL: <reason>)`, with the local path written as inline code. The
  URL exists only when `origin/main` holds byte-identical content to the local file.
- **Three-turn order.** The model ends the final body text of the presentation turn with the
  line as-is and closes the turn; the `CONFIRM_<STAGE>` echo comes alone in a later turn,
  after the user's reply; after Allow the next skill follows in that same turn
  (`skills/_shared/confirm-plan.md` CPA-2/CPA-3). The URL belongs only in that last text
  block, never in the echo. The Stop guard checks the presentation turn and
  `confirm-checkpoint.js` denies an echo that skipped it ([settings/hooks.md](settings/hooks.md)).
- **Breadcrumb `systemMessage`.** `show-plan-link.js` shows the user `Plan file:` plus a
  `[plan-sync]` status line only when something needs attention: no URL for a reason other
  than the project-host verdict. A published plan or a held-back plan shows nothing extra.
- **`bin/plan-link`.** `bin/plan-link [--session <id>] [--stage intent|outline|detail]` is a
  read-only, network-free lookup that prints the same line; the session defaults to
  `CLAUDE_CODE_SESSION_ID`. The model runs it when asked where a plan is. Reasons and their
  resolution live in `hooks/lib/plan-link.js`, shared by the hooks and the CLI.
- **No file sends.** `hooks/block-send-user-file.js` denies `SendUserFile`, so a plan is
  never delivered as a file.
- **Never blocks.** Every failure degrades to a local path plus a reason; the workflow
  continues. The per-turn marker used by the Stop guard is written regardless
  ([settings/hooks.md](settings/hooks.md)).

Code: `hooks/lib/plan-sync.js` (dispatch) and `hooks/lib/plan-sync/{remote-url,
allowlist,provision,git,commit-push,local-file,project-host,init-interactive}.js`; link
resolution `hooks/lib/plan-link.js`.

## Visibility policy

Plans can contain design detail, so the remote must not be public. At provision time the
codehost descriptor's `repoVisibility` is queried (`gh` / `glab`):

| Result | Outcome |
|---|---|
| `public` | Provision refused; nothing is written |
| `private`, `internal` | Accepted |
| unknown, GitLab remote (glab missing, auth failure, malformed host) | Provision refused (`visibility-unverified`); nothing is written and the remote is never contacted |
| unknown, GitHub or no known forge | Note; provisioning continues, the user confirms privacy |

For a GitLab remote the query passes `glab api --hostname <web host>` (with the
non-default HTTP(S) port when the URL has one), so a self-hosted instance is asked about
its own project. The host must match `^[a-z0-9.-]+$` before `glab` is spawned; anything
else is treated as unknown. A GitLab remote that an earlier version already provisioned is
checked the next time `bin/plan-sync-init` is re-run.

A remote on no known forge is accepted but cannot produce a blob URL, so its plan links
carry the local path only (reason `unknown-forge`).

Init also prints a `.private-info-blocklist` note unless the remote's owner/repo appears
in the forge's `listPrivateRepoNames`. That list now returns private **and internal**
repos from one visibility-tagged listing (`hooks/lib/forge/private-repo-list.js`, 4-second
timeout), so `scan-outbound` also blocks public-destination outbound that names an
internal repo ([../../scan-outbound.md](../../scan-outbound.md)).

## Retention

Plans live in the remote repository's history. Deleting a plan locally (`sweep-plans` deletes `plan` files only with `--include-plan-and-user-requested` after an approval prompt)
does not purge it from the remote, and sync never deletes remote files.
Purging requires the user to rewrite or prune the plan repository itself.

## Risks

- **Private-name auto-block is per working-repo forge.** `scan-outbound` derives the
  private repo list from the forge of the *working repo's origin*. A plan repo on a
  different forge (for example plans on GitHub while the working repo is on GitLab or has
  no forge) is not auto-blocked, even when init suppressed the blocklist note. In that
  case add the plan repo to `.private-info-blocklist` manually.
- **Visibility is checked only at provision time.** If the remote is later made public,
  pushes continue. Re-run `bin/plan-sync-init` to re-verify after any visibility change.
- **`plansDir` is trusted local state, but links are not followed.** Sync targets are
  selected by file name, then the file must be a regular file with a single link: symlinks
  and hardlinks are skipped (`[plan-sync]` reason `not-regular-file`). The content is read
  from one verified descriptor (lstat, open, fstat with matching dev/ino), so a swap between
  check and read is rejected rather than published. The Bash trigger fires only when
  `assemble-mandatory.sh` is in command position; a few non-executing forms (quoted
  separators, comments, `bash -n`) still match, but they can only re-publish an existing
  plan file, never another file.
- **A hook input without `cwd` is never synced.** The plan link still carries the local
  path, so the plan is not silently lost.
- **Plan text leaves the machine.** Anything written into an intent, outline or detail
  plan is pushed to the remote, so treat the plan repository as the confidentiality
  boundary and keep its access list short.
