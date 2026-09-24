# GitLab Support

What/Why of GitLab codehost support. How-to configuration lives in `README.md`
and `.env.example`; this document explains the design and its tradeoffs.

## 1. Purpose and background

Forge integration is split into two axes (#2307): a **codehost** axis (pushes,
merge requests, repo visibility, WIP signaling) and a **tracker** axis (issues).
The tracker axis for GitLab shipped earlier; this work implements the codehost
axis. github.com and gitlab.com are recognized out of the box; a self-hosted
A self-hosted GitLab is recognized when its host is set in `GITLAB_HOSTNAME` (or `GITLAB_SSH_HOSTNAME` for SSH-only remotes).

## 2. Detection SSOT

`resolveForgeTarget(url, { gitlabHost })` in `hooks/lib/parse-remote-url.js` is
the single classifier. It is **pure** — no filesystem, no process — so both a CI
shell and a long-running worker get identical verdicts. The self-hosted host is
resolved once by `readGitlabHostConfig(projectRoot)` (which reads `.env` through
the same `load-env.readEffectiveEnvFile` path as `FORGE_TRACKER`, so the two
forge settings can never drift to different sources) and passed in by the caller.

Consumers split by runtime, because the input class differs:
- **Bash scripts** call the `bin/detect-forge-type` CLI (`--field type|host|project`).
- **Node workers** require the resolver in-process (`resolveForgeForWorktree` in
  the commit-push worker). The dispatcher's `runScript` is bash-fixed and cannot
  launch a Node shebang, so a subprocess hop would be the wrong tool; sharing one
  in-process helper between `procedure.js` and `pr.js` also makes their two PR-gate
  verdicts unable to diverge.

## 3. Classification precedence

1. Explicit self-hosted host match (`host === gitlabHost`) → `gitlab`.
2. Fixed registry (`github.com` → github, `gitlab.com` → gitlab).
3. Everything else → `unknown`.

An unknown host is **never** silently reclassified as github — the security
invariant of the two-axis design. An unknown or unreadable origin skips the PR
step and stubs the codehost rather than falling through to the GitHub handler.

A recognized host whose project path cannot be safely extracted is also
downgraded to `unknown`: `extractProjectPath` rejects a `.`/`..` segment, a NUL
byte, or any non-`[A-Za-z0-9._-]` character, because the path is interpolated
into `glab api projects/<path>` (and `gh api repos/<path>`), where a traversal
segment would reach a project the caller never named. No resolvable project means
no forge — fail-safe, applied symmetrically to both forges (CPR-ORTH).

## 4. Codehost API surface

`codehostGitlab` mirrors `codehostGithub`'s signature (CPR-ORTH) and drives
`glab` against the REST API. Nested namespaces (`group/subgroup/project`) are
supported by URL-encoding each path segment and joining with `%2F` before
interpolation.

`is-private-repo.js` routes all three of its entry points through the codehost
descriptor rather than assuming GitHub: `isPrivateRepo` branches per forge,
`listPrivateRepoNames` resolves the CWD's forge descriptor, and
`shouldScanAsPublicTarget` classifies the target by the command's forge. For a
GitLab target, visibility comes from the project's `visibility` field; on any
read failure the fail-safe is the conservative side of each caller (scan / treat
as needing protection), and an unknown host stays private as before.

## 5. Worker path

The commit-push worker resolves the forge in-process: `procedure.js` gates step 8
on `resolveForgeForWorktree`, and `pr.js` opens or reuses a merge request via
`glab api` (creating it with the body on stdin, `-F description=@-`, to keep
author text off the command line). The worker-dispatch registry adds `glab` to
`EXTERNAL_COMMANDS` and to commit-push's `binaries.external`, passes
`GITLAB_TOKEN` / `GITLAB_HOST` through only the `glab` step's `envScope` (so the
token never reaches `git commit` or other steps), and allowlists `GLAB_CONFIG_DIR`.

## 6. Label-based WIP

GitLab Free has no Projects v2 board, so WIP state lives in issue labels:
`status:wip` / `status:done` replace the board Status field, and `wip-fp:<hash>`
replaces the fingerprint field that protects one session's WIP from another's.
`status:*` labels are defined in `.github/labels.yml` (so `sync-labels.sh` keeps
them), and `wip-fp:` is guarded by that script's `protected_prefixes` so a sync
never deletes a live fingerprint. The verbs (`set`/`check`/`clear`/`abandon`/
`setup`) preserve the GitHub exit-code contract and the cross-session protection.

## 7. Accepted tradeoffs

- Projects v2 board → status labels (Free tier has no board).
- Parent/child issue structure → description enumeration (Epics are Premium).
- Roadmap / timeline views → out of scope.
- `.gitlab-ci.yml` generation → deferred to a later change.
- On GitLab visibility read failure, a repo is treated as **private** (name
  redacted). This is the fail-safe / fail-closed direction: `codehostGitlab`
  returns `true` from `isPrivateRepo` whenever `glab` is unavailable or the
  API call fails, so the repo name is never leaked. The single-user local NFR
  assumes `glab` is authenticated for the normal (non-failure) path.

## 8. Cross-repo and subgroup policy

Host cannot be derived from a bare `--repo owner/repo`, so GitLab **rejects**
cross-repo WIP: when `--repo` is set and differs from the CWD's own origin
project, the command exits before any mutation. A `--repo` equal to the CWD
project is harmless and allowed. GitHub keeps its existing `--repo` behavior.
Subgroups are supported through the variable-depth `%2F`-encoded path.

## 9. Not yet supported / future work

Epics, roadmap/timeline, `.gitlab-ci.yml`, and a MSYS2 path-correction helper
for `glab` (added only if a real need appears) are out of scope here.

## 10. Installer DNS reachability guard

Before attempting `glab auth login`, both installer scripts check whether
`GITLAB_HOSTNAME` resolves via DNS (3-second hard timeout). If resolution
fails the auth step is skipped with a yellow WARNING; the glab binary itself
is not removed. This prevents hangs when a `.env` shared from a work machine
is applied on a personal machine that is off-VPN or otherwise cannot reach the
corporate GitLab host.

The `glab auth status` credential-probe fallback was removed from both
installers at the same time: it could silently probe cached credentials for an
unreachable host, bypassing the DNS guard.

Timeout mechanism by platform: `timeout 3 getent hosts` on Linux; a
`gtimeout`/`timeout`/POSIX kill-after chain on macOS; PowerShell
`Start-Job` + `Wait-Job -Timeout 3` on Windows.
