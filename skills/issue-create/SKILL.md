---
name: issue-create
description: Create a task GitHub Issue with the type:task label and add it to Projects v2, after surveying existing issues for duplicates, parents, and siblings.
user-invocable: true
---

The sanctioned path for creating **task issues** (`type:task`) from a Claude Code
session. Surveys existing issues first, classifies the relationship semantically,
then dispatches to a wrapper that handles reopen / sub-issue attach / new-parent
reclassification / sibling cross-reference / plain creation. The dispatcher
delegates new-issue creation to `bin/github-issues/issue-create.sh`.

## Scope

- **In scope**: task issues (`type:task`) for the current repository.
- **Out of scope**: incident issues (use the web UI incident template or
  `gh issue create --label "type:incident"` directly); issues for other repos or
  projects (use `gh issue create --repo OWNER/REPO` directly).

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- `gh` must be authenticated against the current repository.
- `gh` must have the `project` scope for Projects v2 attach. Add with
  `gh auth refresh -s project`.
- The `type:task` label must exist (run `bin/github-issues/sync-labels.sh` if missing).

## Procedure

Four phases: **Gather → Survey → Confirm → Dispatch**.

### Phase 1 — Gather

Collect the proposed title and body from the user.

### Phase 2 — Survey

Skip on non-GitHub remotes:

```bash
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
# rc != 0 → skip survey, jump to Phase 4 with --verdict none
```

**Keyword extraction.** Extract 3–5 significant tokens from the proposed title
(nouns, verbs, technical identifiers; exclude common stopwords).

**Search:**

```bash
gh issue list --state all --limit 30 --search "<kw1> <kw2> <kw3>"
```

If zero results, drop the most specific keyword and retry. Up to 3 attempts.
Still zero → set verdict to `none` and jump to Phase 4.

**Candidate inspection.** Up to ~10 candidates, fetch:

```bash
gh issue view <N> --json number,title,body,state,labels
```

**Verdict classification** (Claude's semantic judgement):

| Class | Verdict | Notes |
|---|---|---|
| **duplicate** (closed or open, same scope) | `reopen` | Confirm before reopening; warn on open-duplicate |
| **superset-open** (existing open issue covers the new one) | `sub-of` | Attach the new issue under the existing parent |
| **siblings-open** (≥2 open issues form a group the new one would head) | `make-parent` | Confirm with user; new issue becomes parent, listed issues become its children |
| **related-open** (overlapping but not subset/superset) | `sibling` | Append `Related to #N` to the new issue body |
| **unrelated** | (ignore) | — |

No match → verdict `none`.

### Phase 3 — Confirm

Confirmation is **required** for `reopen` and `make-parent` (mutating actions on
existing issues). Use `AskUserQuestion`. `sub-of` and `sibling` proceed without
confirmation; `none` proceeds without confirmation.

After a `reopen`: continue the workflow using the existing issue number. Follow
the same routing as `/workflow-init`:
- If the existing issue has `intent:clarified` → Path A (skip interview).
- Otherwise → Path B (pre-fill interview from issue body).

### Phase 4 — Dispatch

```bash
bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-dispatch.sh" \
    --verdict <none|reopen|sub-of|make-parent|sibling> \
    [--target N | --parent N | --children N,M | --related N,M] \
    -- \
    --title "<title>" --body "<body>" \
    [--label "<extra-label>" ...] [--assignee "<user>"] [--milestone "<name>"]
```

Stdout is the final issue URL (one line). For `reopen` it is the reopened
issue's URL; otherwise it is the newly created issue's URL. Report it to the
user.

## Label policy

- `type:task` is attached unconditionally by the underlying script.
- Additional non-`type:*` labels (e.g. `area:hooks`, `priority:high`) may be
  passed via `--label`. `type:*` is rejected to avoid confusing
  `/issue-close-finalize` routing.

## Behavioral notes

- **Survey first**: this skill surveys existing issues before creation; see
  Phase 2. The underlying `bin/github-issues/issue-create.sh` does not dedupe
  by title — the survey phase is the dedupe layer.
- **Projects v2**: `PROJECT_NUM=1` and owner `nirecom` are the defaults.
  Override via `ISSUE_CREATE_PROJECT_NUM` / `ISSUE_CREATE_OWNER`.
- **Content Date field**: after Projects v2 attach, the underlying script sets
  the "Content Date" custom field to the issue's creation date (`YYYY-MM-DD`).
  Defaults: `ISSUE_CREATE_FIELD_ID=PVTF_lAHOAMF_jc4BXf9EzhSsYwA`,
  `ISSUE_CREATE_PROJECT_ID=PVT_kwHOAMF_jc4BXf9E`. Failure is non-fatal.
- **Attach failure is non-fatal**: the issue is created regardless; warnings on
  stderr. Re-run `gh project item-add` manually if recovery is needed.
- **Sub-issue API**: the dispatcher uses `POST /repos/{owner}/{repo}/issues/{N}/sub_issues`
  with `sub_issue_id` set to the **child's** GraphQL node id (`gh issue view <child> --json id`).
- **make-parent partial failure**: if a child attach fails mid-loop, the parent
  is created but `make-parent` exits non-zero with retry instructions on
  stderr. Atomic semantics are not available (GitHub has no transactions).
- **Untrusted content**: title/body are passed as separate arguments to `gh` —
  no shell expansion. Do not interpolate unvalidated user input into `--title`.
