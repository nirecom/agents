---
name: issue-setup
description: Sync the target repo's labels and create/link its Projects v2 board to make it ready for GitHub Issues.
user-invocable: true
---

Initialize a target repo for GitHub Issues: sync its label set and create/link a Projects v2 board.

## Scope

- Sync the target repo's label set (from `agents/.github/labels.yml`) and initialize its Projects v2 board.
- Cross-repo aware: the target repo may differ from the CWD repo.
- Non-GitHub remote: skip and notify the user.

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- `gh` must be authenticated with the `project` scope; if absent, tell the user to run `gh auth refresh -s project` and stop.
- Run `bin/is-github-dotcom-remote` against the target repo; on rc=1, exit 0 with a notice.

## Procedure

IS-1. Confirm the target repo via AskUserQuestion:
- `current`: use the CWD repo (resolve via `gh repo view`).
- `other`: prompt for an `OWNER/REPO` string.

IS-2. Sync labels (no confirmation — automatic): run `run-issue-setup.sh --step labels --repo "$TARGET_REPO"`.

IS-3. Check the project: run `run-issue-setup.sh --step check-project --repo "$TARGET_REPO"` → rc=0 present / rc=1 absent.

IS-4. When the project is absent, AskUserQuestion:
- `create`: run `run-issue-setup.sh --step ensure-project --repo "$TARGET_REPO"`.
- `skip`: notify the user that a manual link is required, then exit 0.

IS-5. Report the outcome to the user.

Backend script path: `$AGENTS_CONFIG_DIR/skills/issue-setup/scripts/run-issue-setup.sh`.
