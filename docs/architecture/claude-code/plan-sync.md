# Plan Sync

Publishes each final session plan (`<sid>-intent.md`, `-outline.md`, `-detail.md`) to a
private git remote so the plan can be read from the iOS/Android Claude apps or any
browser, not only from the machine that wrote it (#2513).

## Why

The plan confirmation steps (`CONFIRM_INTENT` / `CONFIRM_OUTLINE` / `CONFIRM_DETAIL`)
ask the user to read a plan before approving it. A bare local path is useless away from
the desktop. The earlier answer was to auto-open the file in a VS Code window; that
needed a VS Code session on the same machine and was removed. A forge blob URL works on
every device that can sign in to the forge, so the model now writes that URL in the
conversation body.

Plan sync is a sibling of [session-sync](session-sync.md) and uses the same remote-URL
format, but it is a different mechanism: session-sync moves whole session history on
demand; plan-sync publishes the existing plans once at init, then pushes one plan file
at the moment it is written.

## Setup

1. Create an empty **private** (or internal) repository yourself — no README needed — or
   let the interactive setup create it (see below). Init pushes the first commit to the
   empty repo.
2. Set it in `agents/.env` (gitignored; template in `.env.example`):

   ```
   PLAN_SYNC_REMOTE_URL=git@github.com:YOUR_USERNAME/agent-plans.git
   ```

   SSH (`git@github.com:…`) or HTTPS (`https://github.com/…`) both work. HTTPS needs
   credentials that never prompt (Git Credential Manager, `gh auth setup-git`); never put
   a token inside the URL. Empty (the default) turns plan sync off; the model is told
   the plan is not published and no URL is shown.
3. Provision once with `bin/plan-sync-init` (Windows wrapper
   `install/win/plan-sync-init.ps1`; `install.sh` / `install.ps1` call it too). It is
   idempotent and safe to re-run, and must be re-run after changing the URL.

**Interactive setup.** When no remote is configured (empty or the `.env.example`
placeholder), no `--remote-url` is given, and stdin is a TTY, init runs
`hooks/lib/plan-sync/init-interactive.js` instead of stopping. It uses `gh`: the signed-in
login proposes `<login>/agent-plans`. An existing private repo is offered for reuse; a
public or internal one aborts; an absent one is created `--private` after a y/N prompt.
Init then provisions, and asks y/N before writing `PLAN_SYNC_REMOTE_URL` into the agents
`.env` (atomic temp-file + rename, replacing every existing `PLAN_SYNC_REMOTE_URL` line).
If SSH provisioning fails it prints a hint (`ssh -T git@github.com`, or the HTTPS URL after
`gh auth setup-git`). Non-interactive runs behave as before.

`PLAN_SYNC_REMOTE_URL` is on the `.env.local` overlay blocklist (see
[local-env-overrides.md](local-env-overrides.md)): a project must not redirect where
every plan is published. `--remote-url` on the init CLI overrides the hook-resolved
value; because the hook keeps reading env then `.env`, init warns after success when the
two differ.

## How it works

Two phases with different costs.

**Provision (once, `bin/plan-sync-init`).** Turns the plans directory
(`PLANS_DIR`, `~/.workflow-plans/` by default) into a git working tree: `git init`,
`HEAD` pointed at `main`, hooks/fsmonitor/autocrlf neutralised, `origin` set, the
allowlist `.gitignore` written, and the local plans converged with the remote. Every plan
file already in the plans directory is published in the same commit, so plans written
before sync was set up reach the remote too. A name the remote already holds is never
overwritten, and re-running init publishes only the plans the remote lacks. The init
version is recorded in local git config. Visibility is checked here (see below).

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
- **Plan link in the main conversation.** `systemMessage` is shown faintly on the PC only;
  only body text reaches the iOS/Android Remote Control apps. So the hooks hand the model
  the plan link as `hookSpecificOutput.additionalContext` (`[plan-link]`): the blob URL, or
  a reason code when there is none (never a local path). `show-plan-link.js` does this
  after a write and `confirm-checkpoint.js` before a CONFIRM. The URL exists only when
  `origin/main` holds byte-identical content to the local file. The model must write it in
  its response text (`skills/_shared/confirm-plan.md` CPA-2 / CPA-3 own that obligation),
  and the Stop guard's Layer 3 enforces it ([settings/hooks.md](settings/hooks.md)).
- **Breadcrumb `systemMessage`.** `show-plan-link.js` emits the `Plan file:` breadcrumb
  plus a `[plan-sync]` status line only when sync produced no URL (not configured, not
  provisioned, failed, or a non-GitHub remote). On success it is suppressed. A failed sync
  of a file already published unchanged still recovers the URL for the model but keeps the
  breadcrumb. `confirm-checkpoint.js` always emits its `systemMessage` with the context.
- **`bin/plan-link`.** `bin/plan-link [--session <id>] [--stage intent|outline|detail]` is a
  read-only, network-free lookup printing `<stage>: <blob URL>` or
  `<stage>: (unavailable: <reason>)`; the session defaults to `CLAUDE_CODE_SESSION_ID`. Use
  it to answer "where is the plan". Reason codes and resolution live in
  `hooks/lib/plan-link.js`, shared by the hooks and the CLI.
- **No file sends.** `hooks/block-send-user-file.js` denies `SendUserFile`, so a plan is
  never delivered as a file.
- **Never blocks.** Every failure degrades to a reason plus warning; the workflow continues.
  The per-turn marker used by the Stop guard is written regardless
  ([settings/hooks.md](settings/hooks.md)).

Code: `hooks/lib/plan-sync.js` (dispatch) and `hooks/lib/plan-sync/{remote-url,
allowlist,provision,git,commit-push,local-file,init-interactive}.js`; link resolution
`hooks/lib/plan-link.js`.

## Visibility policy

Plans can contain design detail, so the remote must not be public. At provision time the
codehost descriptor's `repoVisibility` is queried (`gh` / `glab`):

| Result | Outcome |
|---|---|
| `public` | Provision refused; nothing is written |
| `private`, `internal` | Accepted |
| unknown (tool missing, auth failure, stub forge, malformed GitLab host) | Warning; provisioning continues, the user confirms privacy |

For a GitLab remote the query passes `glab --hostname <host>`, so a self-hosted instance is
asked about its own project. The host must match `^[a-z0-9.-]+$` before `glab` is spawned;
anything else is treated as unknown.

A non-GitHub remote is accepted but cannot produce a blob URL, so the plan link reports
reason `non-github` and the breadcrumb keeps the local path.

Init also prints a `.private-info-blocklist` note unless the remote's owner/repo appears
in the forge's `listPrivateRepoNames`. That list now returns private **and internal**
repos from one visibility-tagged listing (`hooks/lib/forge/private-repo-list.js`, 4-second
timeout), so `scan-outbound` also blocks public-destination outbound that names an
internal repo ([../../scan-outbound.md](../../scan-outbound.md)).

## Retention

Plans live in the remote repository's history. Deleting a plan locally (for example via
`sweep-plans`) does not purge it from the remote, and sync never deletes remote files.
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
- **Plan text leaves the machine.** Anything written into an intent, outline or detail
  plan is pushed to the remote, so treat the plan repository as the confidentiality
  boundary and keep its access list short.
