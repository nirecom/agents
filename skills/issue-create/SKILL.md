---
name: issue-create
description: Create a task GitHub Issue with the type:task label and add it to Projects v2.
user-invocable: true
---

The sanctioned path for creating **task issues** (`type:task`) from a Claude Code
session. Wraps `gh issue create` with enforced labeling and automatic Projects v2
attachment.

## Scope

- **In scope**: task issues (`type:task`) for the current repository.
- **Out of scope**: incident issues (use the web UI incident template or
  `gh issue create --label "type:incident"` directly); issues for other repos or
  projects (use `gh issue create --repo OWNER/REPO` directly).

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- `gh` must be authenticated against the current repository.
- `gh` must have the `project` scope for Projects v2 attach. Add with
  `gh auth refresh -s project` (browser-based OAuth). The script warns
  on stderr if the scope is missing; issue creation still proceeds but
  the attach step fails.
- The `type:task` label must exist (run `bin/github-issues/sync-labels.sh` if missing).

## Procedure

Gather the issue title and body from the user, then invoke the helper script:

```bash
bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create.sh" \
    --title "<title>" \
    --body  "<body>"  \
    [--label "<extra-label>" ...] \
    [--assignee "<user>"] [--milestone "<name>"]
```

Report the created issue URL to the user. Capture the number from the URL if
subsequent steps need to reference it:

```bash
URL=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create.sh" \
    --title "..." --body "...")
NUM=$(printf '%s' "$URL" | grep -oE '[0-9]+$')
```

## Label policy

- `type:task` is attached unconditionally by the script.
- Additional non-`type:*` labels (e.g. `area:hooks`, `priority:high`) may be
  passed via `--label`. The script rejects any `type:*` value to avoid
  confusing `/issue-close` routing.

## Behavioral notes

- **Idempotency**: the skill does **not** dedupe by title. Re-running creates a
  second issue. Check existing issues first if deduplication matters.
- **Projects v2**: `PROJECT_NUM=1` and owner `nirecom` are the defaults, matching
  `bin/github-issues/migration/backfill-content-date.sh`. Override via
  `ISSUE_CREATE_PROJECT_NUM` / `ISSUE_CREATE_OWNER` env vars.
- **Content Date field**: after a successful Projects v2 attach, the script automatically
  sets the "Content Date" custom field to the issue's creation date (`YYYY-MM-DD`).
  Defaults: `ISSUE_CREATE_FIELD_ID=PVTF_lAHOAMF_jc4BXf9EzhSsYwA`,
  `ISSUE_CREATE_PROJECT_ID=PVT_kwHOAMF_jc4BXf9E`. Override via env vars when
  using a different project. Content Date set failure is non-fatal — a warning is
  emitted on stderr and the issue URL is still returned normally.
  Requires `gh project item-add --format json --jq` support (available since gh v2.x).
- **Attach failure is non-fatal**: the issue is created regardless. A warning is
  printed; re-run `gh project item-add` manually if recovery is needed.
- **Untrusted content**: title/body are passed as separate arguments to `gh` —
  no shell expansion. Do not interpolate unvalidated user input into `--title`.
