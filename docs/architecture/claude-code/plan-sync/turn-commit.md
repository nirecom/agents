# plan-sync: one commit per user prompt

Parent: [../plan-sync.md](../plan-sync.md). Issue #2768.

## Why

A plan is often written several times while answering one user prompt (draft, review fix,
re-assembly). One commit per write filled the plan repository with intermediate versions the
user never saw, and each plan link pointed at a state that was already outdated by the end of
the turn. plan-sync therefore folds every write of one user prompt into one commit, and still
keeps every version the user actually saw.

## Turn id

- `hooks/user-prompt-submit-turn-id.js` (UserPromptSubmit) gives each user prompt a fresh random
  id in `<sid>.control/prompt-turn.json` ([../state-dirs.md](../state-dirs.md)). It removes the
  previous file first, so a later failure leaves no id rather than the previous prompt's id.
- `hooks/show-plan-link.js` reads the id when a plan or session-progress file is written and
  passes it to plan-sync. Without an id, the write is committed as before (append, no
  replacement).
- session-progress.md is handled like the plan files: its silent sync joins the same turn
  commit.

## Commit format

Each turn commit carries trailers naming the session, the turn, the turn's base commit
(`Plan-Sync-Turn-Base`) and the files written in the turn. `hooks/lib/plan-sync/turn-trailer.js`
owns the exact format; this document does not restate it.

- The file list holds only files whose content changed in the turn. A file changed and then
  restored stays in the list but shows no diff; a write with identical bytes is not listed.
- The base is the commit before the turn's first commit. When the history cannot be read, the
  base is recorded as `unknown` and no turn-diff link is produced (fail closed: a guessed base
  could show a diff that includes other turns' changes).

## Replacing the turn commit

A later write in the same turn rebuilds the turn commit on its parent and pushes it with
`--force-with-lease`. The tip is replaced only when it is plan-sync's own commit (plan-sync's
commit identity) for the same session and turn, with a single parent; anything else gets a new
commit on top.

- **Lease miss** (the remote moved): plan-sync fetches and rebuilds against the new tip.
- **Forced update refused by the remote** (a protected branch): plan-sync appends a commit
  instead, and remembers the refusal for that push URL, so later turns append directly.

## Turn-diff link

When the remote refuses forced updates, one turn can span several commits. The hook then prints
a `[plan-sync] turn diff` line, with its own instruction, before the `[plan-link]` lines:

- a compare link from the turn base to the tip when no other commit interleaves;
- otherwise per-commit links, at most 5, followed by "+N more".

No link is printed while forced updates are accepted (the plan link already shows the whole
turn), nor when the base is `unknown`.

## Auth-failure backoff

After an authentication failure, plan-sync stops pushing to that push URL for 15 minutes, so a
broken credential does not cost a timed-out push on every write. Content already published keeps
its URL during the backoff. `bin/plan-sync-init` clears the backoff and the remembered force
refusal; both are bound to the push URL, so a changed remote starts clean.

## Residual risks

- **Turn id not cleared.** When the turn-id hook does not run (not started, unreadable stdin or
  session id, a load failure), the previous prompt's id stays in place and the new prompt's
  writes can replace the previous prompt's commit; that version is then missing from the remote
  history.
- **Stale tracking ref.** If git is killed after the remote accepted a push but before the local
  tracking ref is updated, the next write hits a lease miss, fetches, and replaces the same turn
  commit — it converges to one commit.
- **Budget exhaustion.** When the sync budget runs out mid-push, the write degrades to the local
  path (no URL) and recovers on the next write.
- **Force refusal learned late.** The refusal is recorded only after the follow-up append push
  succeeds; until then one extra push per write is spent, bounded by the auth backoff.
- **Misclassified refusal.** A transient pre-receive rejection can be recorded as a force
  refusal; the turn then appends until `bin/plan-sync-init` clears it.
- **Link cap.** A turn with more than 5 interleaved commits lists only the first 5.
- **Copied trailer.** The tip check reads the commit identity and the trailer (session id and
  turn id), not the machine. A commit from another machine that carries the same identity and
  trailer, such as a cherry-pick or a copy, can be replaced. Such a commit exists only when
  someone copies it on purpose.

Code: `hooks/lib/plan-sync/{turn-trailer,turn-commit,lease-push,remote-state,commit-push}.js`,
`hooks/lib/prompt-turn-id.js`, `hooks/user-prompt-submit-turn-id.js`,
`hooks/show-plan-link.js` with `hooks/show-plan-link/turn-diff.js`.
