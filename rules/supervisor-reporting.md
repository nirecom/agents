# EM Supervisor Reporting

## When to Report

Report when you observe any of the following during skill or agent execution:

- Trouble signs: something looks off but no failure yet — "I'm not sure this is right" counts
- Incidents: a confirmed failure, violation, or unexpected outcome
- Neutral observations worth recording for cross-session pattern detection
- When in doubt: `WORKFLOW_OFF`/`WORKTREE_OFF` sentinel used; hook blocked a sanctioned command and required a workaround; fallback path taken instead of primary; step needed a retry or manual intervention — all warrant a report.

To report, run `/supervisor-report` — it owns the fields, the category and severity tables, and the CLI call.
