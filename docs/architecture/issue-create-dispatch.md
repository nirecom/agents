# /issue-create dispatch internals

Behavior of `bin/github-issues/issue-create-dispatch.sh` and `bin/github-issues/issue-create.sh` that `/issue-create` (`skills/issue-create/SKILL.md`) relies on but does not direct.

## Projects v2 attach

The linked Projects v2 (owner, number, node id) is auto-resolved from the git remote via `bin/github-issues/lib/resolve-project.sh` (#641).
There are no hardcoded defaults: a repo without a linked Projects v2 skips the attach step with a warning.
The result is cached per `owner/repo` at `${WORKFLOW_STATE_DIR}/cache/project-resolve.tsv`.
Attach failure is non-fatal: warnings go to stderr; re-run `gh project item-add` manually to recover.

## Content Date field

When the resolved project has a field named "Content Date" of type `DATE`, the script sets it to the issue's creation date (`YYYY-MM-DD`).
The field id is discovered alongside the project node, so no env var override is needed.
A project without a Content Date field skips the step silently.

## Sub-issue API

The dispatcher calls `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` with `sub_issue_id` set to the child's integer databaseId, passed via `-F` (integer type).
The databaseId comes from `gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: N) { databaseId } } }' --jq '.data.repository.issue.databaseId'`.

## Partial failure

GitHub has no transactions, so neither multi-issue verdict is atomic.

- `make-parent`: if a child attach fails mid-loop, the parent and the proposal already exist; their URLs are still emitted, and the dispatcher exits non-zero with retry instructions on stderr.
- `bulk-sub-of`: if any child create or attach fails, the URLs created so far are still emitted and recorded; the dispatcher writes retry info to stderr and exits non-zero. The manifest is kept so the rows not yet created can be identified; never re-run the whole manifest, because the created rows would be duplicated.
