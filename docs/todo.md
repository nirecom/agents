# Todo

Active tasks are tracked in GitHub Issues:

- List: `gh issue list --state open`
- Web: <https://github.com/nirecom/agents/issues>

Complete a task with `/issue-close-stage <N>` (Phase 1, from the linked
worktree before `/commit-push`) then `/issue-close-finalize <N>` (Phase 2,
from the main worktree after the PR is merged).

- [ ] agents/commit-push-worker.md の内部 `1.5.` / `3.0.` decimal label を §4.1 準拠 (CPW-N など) に renumber する (deferred from #966)
