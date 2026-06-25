---
name: issue-reconcile-worker
description: Paginate closed issues, classify each as clean/needs-reconcile/history-only, and write a JSONL artifact listing only needs-reconcile issues. Read-only scan — no issue mutations.
tools: Bash, Read, Write
model: sonnet
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Scan closed issues for missing `<!-- issue-close-sentinel: appended -->` markers and classify each.

## Input contract

Receive a JSON object with:
- `owner_repo`: `owner/repo` string
- `history_md_path`: absolute path to `docs/history.md`
- `history_dir_path`: absolute path to `docs/history/` directory (for archive lookups)
- `agents_config_dir`: absolute path to agents config dir
- `artifact_dir`: directory for output files

## Procedure

1. Paginate all closed issues (repeat with `--page N` until no more results):
   `gh issue list --repo "$owner_repo" --state closed --limit 100 --page N --json number,title,comments`

2. Per issue, classify:
   - `clean`: has a comment whose body starts with `<!-- issue-close-sentinel: appended`.
   - `history-only`: no sentinel comment AND a history entry matching `#<N>:` exists in `history_md_path` or under `history_dir_path/`.
   - `needs-reconcile`: no sentinel comment AND no history entry found.

3. Write non-clean issues with classification `needs-reconcile` to a JSONL artifact at `$artifact_dir/<timestamp>-issue-reconcile-worker.jsonl`. One JSON object per line: `{ "number": N, "title": "...", "state": "closed", "classification": "needs-reconcile" }`. Omit `clean` and `history-only` entries.

4. Write progress log to `$artifact_dir/<timestamp>-issue-reconcile-worker.log`.

## Rules

- Read-only scan: issue mutations (comment posting, history append, issue close) are prohibited.
- Worker context: no sentinel emission, no interactive confirmation, no skill invocations.
- Do not install packages.

## Output contract

Respond with exactly three lines:

```
status: complete|failed
summary: <N scanned; M to reconcile>
artifact_path: <absolute path to JSONL file, or (none) on failure>
```

No other output.
