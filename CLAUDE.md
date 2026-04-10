# Global Claude Code Instructions

## Workflow

Create the following as a TodoWrite checklist and work through each step in order.

1. **Research** — Run `/survey-code` and/or `/deep-research`.
   - `/survey-code`: Skip when the change target is already known (single file/function).
   - `/deep-research`: Skip when no external knowledge is needed.
2. **Plan** — Run `/make-plan` (planner/reviewer discussion → approval).
   - Skip when: the task is a single-file change AND no design decision is needed.
   - Skipping Research does NOT justify skipping Plan.
   Run `/review-security` when the plan involves secrets, third-party services, or external input.
3. **Write tests** — **Always write or update tests before modifying source code.** Run `/write-tests`.
4. **Code** — Present a diff in chat before calling Edit. Wait for approval.
5. **Test & Verify** — Run tests. Complete any additional verification and report results.
6. **Docs** — Run `/update-docs`.
7. **User verification** — Wait for the user to confirm the task is complete.
8. **Commit** — Run `/commit-push`.
