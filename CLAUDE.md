# Global Claude Code Instructions

## Workflow

1. **Plan** — Run `/make-plan` and get approval. Skip only if the task is describable in one sentence.
2. **Write tests** — **Always write or update tests before modifying source code.** See `rules/test.md`.
3. **Code** — Present a diff in chat before calling Edit. Wait for approval.
4. **Test & Verify** — Run tests. Complete any additional verification and report results.
5. **Docs** — Run `/update-docs`.
6. **User verification** — Wait for the user to confirm the task is complete.
7. **Commit** — Run `/commit-push`.
