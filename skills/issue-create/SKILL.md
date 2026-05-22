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

Collect title and canonical-schema body from the user.

Required body schema for `type:task` (enforced by `bin/github-issues/issue-create.sh` exit 3):

| Field | Shape variants accepted |
|---|---|
| `Background` | `Background: <text>` / `## Background` / `### Background` |
| `Changes`    | `Changes: <text>` / `## Changes` / `### Changes` |

When the user-provided body is missing one or both required fields, use `AskUserQuestion` with these branches:
- `fix-now`: re-author the body inline with the missing field(s) added.
- `template`: prefill the 2-section template `## Background\n<TBD>\n\n## Changes\n<TBD>` and ask the user to fill it.
- `bypass`: set `ISSUE_CREATE_SKIP_SCHEMA=1` for this invocation — emergency escape hatch; sanctioned path is always to add the missing fields.

### Phase 2 — Survey

Dedupe layer for the underlying `bin/github-issues/issue-create.sh`. Skip on non-GitHub remotes:

```bash
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
# rc != 0 → skip survey, jump to Phase 4 with --verdict none
```

**Keyword search.** Extract 3–5 significant tokens (nouns/verbs/identifiers, no stopwords), then:

```bash
gh issue list --state all --limit 30 --search "<kw1> <kw2> <kw3>"
```

Zero results → drop most specific keyword, retry up to 3 times. Still zero → verdict `none`, jump to Phase 4.

**Candidate inspection** (up to ~10): `gh issue view <N> --json number,title,body,state,labels`.

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

**Stdout contract**: Phase 4 emits exactly one line to stdout on success: the issue URL (`https://github.com/<owner>/<repo>/issues/<N>`). All other output goes to stderr. Callers extract the issue number with: `echo "$OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$'`. Enforced by `bin/github-issues/issue-create-dispatch.sh`.

## Label policy

- `type:task` is attached unconditionally by the underlying script.
- Additional non-`type:*` labels (e.g. `area:hooks`, `priority:high`) may be
  passed via `--label`. `type:*` is rejected to avoid confusing
  `/issue-close-finalize` routing.

## Behavioral notes

- **Projects v2**: defaults `PROJECT_NUM=1`, owner `nirecom`. Override via `ISSUE_CREATE_PROJECT_NUM` / `ISSUE_CREATE_OWNER`. Attach failure is non-fatal — warnings on stderr; re-run `gh project item-add` manually to recover.
- **Content Date field**: after attach, the script sets "Content Date" to the issue's creation date (`YYYY-MM-DD`). Defaults: `ISSUE_CREATE_FIELD_ID=PVTF_lAHOAMF_jc4BXf9EzhSsYwA`, `ISSUE_CREATE_PROJECT_ID=PVT_kwHOAMF_jc4BXf9E`. Failure is non-fatal.
- **Sub-issue API**: dispatcher uses `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` with `sub_issue_id` = child's GraphQL node id (`gh issue view <child> --json id`).
- **make-parent partial failure**: if a child attach fails mid-loop, the parent is created but `make-parent` exits non-zero with retry instructions on stderr. No atomic semantics (GitHub has no transactions).
- **Untrusted content**: title/body are passed as separate `gh` arguments — no shell expansion. Do not interpolate unvalidated input into `--title`.
- **Schema enforcement (#443)**: `bin/github-issues/issue-create.sh` exits 3 when `Background` or `Changes` is missing. `ISSUE_CREATE_SKIP_SCHEMA=1` is an emergency escape hatch only — the sanctioned path is to add the missing fields. Incident issues (`type:incident`) bypass this skill entirely per Scope.
