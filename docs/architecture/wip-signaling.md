# WIP Signaling — the session-id holder value

How a session marks an issue as "work in progress by me", and why the marker is the raw
Claude Code session id (#2925, with the narrowed field recovery of #2161).

## 1. What is recorded

- GitHub: the board item gets Status `In Progress` and the text field `session-id` holds the
  raw session id of the holder (`bin/github-issues/wip-state.sh`).
- GitLab: the issue gets the label `status:wip` plus one holder label `wip-fp:<session-id>`
  (see [gitlab-support.md §6](gitlab-support.md#6-label-based-wip)).
- `check` answers `same` only when the stored value equals the caller's session id; anything
  else under In Progress is `other`, and the workflow offers the wip_conflict choice.
- The reopen banner and reopen log (`bin/github-issues/reopen-with-update.sh`) carry the same raw
  id, so every place that tells sessions apart uses one value. Both resolve the id through
  `bin/resolve-session-id`; reopen takes no `--session-id` argument and records `unknown` when
  the id cannot be resolved (nothing reads that line back).

## 2. Why the raw id, not a digest

The value used to be the first 8 hex of `sha256(session_id:N)`. No motive for the hashing was
ever recorded, and the investigation behind #2925 found nothing it protects:

- A Claude Code session id is a UUID that names a local transcript file. Resuming reads that
  local file; knowing the id does not let another machine take the session over.
- No advisory or vulnerability report covers session ids; resuming someone else's session exists
  only as a feature request.
- Anyone who can write to the board can write any value, digest or not, so the digest is no
  tamper protection either.
- The digest only prevented correlating one session across public repos — a correlation
  concern, not a takeover risk; it was accepted as a tradeoff.

The raw id also lets a person read the holder in the web UI and match it with the session that
filed or commented on an issue.

## 3. No compatibility with the old values

- Old 8-hex values left on items are never read or translated. A session that spans the switch
  sees `other` on its own issue and proceeds by choosing Continue in wip_conflict.
- The legacy text field `session-fingerprint` is never deleted and its values are never read.
- On GitLab, old `wip-fp:<8 hex>` labels stay defined; `set` removes every `wip-fp:*` label other
  than its own in the same edit.

## 4. The field name and who may create or rename it

- The name `session-id` and the legacy name live only in `bin/github-issues/lib/session-id-field.sh`.
- `/issue-setup` (ensure-project-ready) only creates `session-id` when absent. On a project that
  still has the legacy field, both fields then sit side by side; the legacy one is ignored.
- Only the `set` verb recovers: when no `session-id` field resolves, it renames the legacy field
  in place (the field id is kept), or creates `session-id` when neither exists. `check`, `clear`
  and `abandon` never create or rename — a project in an abnormal state should not be changed
  by a read or a cleanup.
- When neither recovery succeeds, `set` exits 1 with a hint (project scope or `/issue-setup`); the
  WIP for that issue is skipped and the workflow continues.

## 5. A field that disappears after it was cached

A cached field id can point at a field deleted on the board. After a write to that id fails,
the verb asks whether the field still exists. Only when it is gone does it drop the cache row,
resolve afresh, and retry once with the fresh id. A failure for any other reason (network,
scope) is not retried, so a transient error never turns into repeated mutations.

Per verb, when no field can be obtained:

- `set` — recovers as in §4, otherwise exits 1.
- `check` — an In Progress item without a field is `other` (the holder cannot be shown to be us).
- `clear` — nothing to empty; it warns on a failed clear and continues (the close already happened).
- `abandon` — nothing to empty counts as success; a failed clear exits 1.

## 6. Resolver cache

The per-repo cache row has 11 columns ending with the schema tag `sid1`. A row with another
column count or tag is a miss and is rewritten by the next fresh resolve, so rows from the
digest era never feed a stale field id into the new code. The verbs resolve with
`--require-wip-fields`, so a row lacking the WIP field ids is also a miss.

The resolver's field query reads the first 50 fields only. A `session-id` field beyond that page
resolves as absent; the `set` recover pages through every field, finds it, and writes it to the
cache, so no duplicate field is created. That paging stops after 20 pages and then treats the
listing as complete; a field beyond that point would be missed and `set` would try to create
another `session-id`. Projects that large are out of scope.

## 7. Board view visibility

A text field is hidden on board views by default. After creating the field, ensure-project-ready
adds it, best effort, to every board-layout view that lacks it, passing the full list of already
visible fields so none of them disappears. A failure only warns. If the platform rejects this,
show the field by hand from the view's field menu.

A board view whose visible field list spans more than one page is skipped with a warn, because
sending a partial list would hide the remaining fields; add the field to that view by hand.
Before each update, the view's `visibleFieldIds before update` line is logged; to restore a view
by hand, pass those ids to `updateProjectV2View`.

## 8. GitLab atomicity

`glab issue edit` sends the added and removed labels in one request, so `set` replaces the holder
label atomically instead of removing first and adding second. A failed label read makes `set`
exit 1 without any edit, and a session id outside `[A-Za-z0-9_-]` (a comma would split the label)
makes `set` and `check` exit 1 without touching labels.
