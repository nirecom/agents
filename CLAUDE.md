# Global Claude Code Instructions

## Workflow

1. **Research** — Run `/survey-code` and/or `/deep-research` as needed.
   - `/survey-code`: Explore own codebase. Skip if the change target is already known (single file/function) or the task is describable in one sentence.
   - `/deep-research`: Investigate external info (APIs, libraries, best practices). Skip if no external knowledge is needed.
2. **Plan** — Run `/make-plan` and get approval. Skip only if the task is describable in one sentence.
3. **Write tests** — **Always write or update tests before modifying source code.** See `rules/test.md`.
4. **Code** — Present a diff in chat before calling Edit. Wait for approval.
5. **Test & Verify** — Run tests. Complete any additional verification and report results.
6. **Docs** — Run `/update-docs`.
7. **User verification** — Wait for the user to confirm the task is complete.
8. **Commit** — Run `/commit-push`.
