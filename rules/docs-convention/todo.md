---
globs: "docs/todo.md"
---

## todo.md Rules

- Current Work section first. Status Summary has incomplete phases only (completed → `history.md`).
- When updating todo.md after completing implementation work, add a **user verification step** as the next action item. The phase/task stays in Current Work with "Verifying" status until the user confirms completion. Do not move it to `history.md` until verification passes.
- Once verification passes, **move** the completed phase/step to `history.md` and **fully remove** it from `todo.md` — do not leave `[x]` checkboxes, completed sub-steps, or stub pointers back to `history.md`. The entry must exist in exactly one place. Status Summary likewise drops completed phases.
- After editing `todo.md` from the main worktree, commit immediately.
