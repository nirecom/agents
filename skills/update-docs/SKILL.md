---
name: update-docs
description: Update all project documentation to reflect recent changes
model: sonnet
user-invocable: false
---

Update all project documentation to reflect recent changes.

Docs directory: `docs/` within the current project root.
Target files: all `.md` files in `docs/` that already exist, plus `README.md` in the project root.

## Procedure

1. **Gather recent changes**:
   - Run `git diff` and `git diff --cached` to capture uncommitted and staged changes (current session's work, not yet in git log)
   - Run `git log --oneline -20` for committed history
2. **Read current docs**: Read all target docs files.
   - `README.md` (repo root) is required for all repos. **Create it first if missing — highest priority.**
     - Goal: make the reader think "I want to use this" — crisp features, "what it does for you"
     - Initial install/setup instructions go here, not in `ops.md`
   - `CHANGELOG.md` (repo root) for public repos. Create if missing (no manual seed needed — first run starts from here).
3. **Identify gaps**: Compare git log against each document's content. Look for:
   - Unrecorded commits or phases
   - Architecture/design changes not yet documented
   - New incidents or bug fixes
   - Infrastructure or operational changes
   - Progress updates
   - `README.md`: Update when a user-visible feature is added or changed, install/usage steps shift, or an existing bullet no longer accurately reflects real behavior.
4. **Propose updates**: For each file that needs updating, present:
   - Which sections need changes and why
   - Specific additions or modifications
5. **Apply after confirmation**: Edit files only after user approval
6. **Propagate to parent docs**: If the project has a parent-level summary doc (e.g. an engineering hub), update it too. Skip for repo-local `docs/`.
   - Skip `infrastructure.md` — delegate to `/update-infrastructure` instead.
7. **Commit separately**: If docs are in a separate repo, commit each repo independently

## Rules

- Follow the structure and content rules defined in `rules/docs-convention.md`
- Follow the gather → propose → confirm → apply cycle (never write without user confirmation)
- Compare git log against current docs to identify gaps

## Completion

After completing this skill, choose Path A or Path B based on `ENFORCE_WORKTREE`.

### Path A — ENFORCE_WORKTREE=on (mandatory)

1. Append history bullets to `<worktree>/WORKTREE_NOTES.md` `## History Notes`. Replace `- (none)` on first append.
2. For public repos: append user-facing bullets to `## Changelog Notes`. Replace `- (none)` on first append.
3. Do NOT write `docs/history.md` or `CHANGELOG.md` directly — deferred to `/worktree-end` Step 6i.
4. Stage: `git add docs/ README.md` (intentionally omits `CHANGELOG.md` and `docs/history.md`).
5. Commit gate is satisfied by `docs/` staged entries (architecture.md, ops.md, README.md, etc.).
6. Wait for user verification; emit `<<WORKFLOW_USER_VERIFIED: <reason>>>` and invoke `commit-push`.

### Path B — ENFORCE_WORKTREE=off

1. `doc-append docs/history.md --category CATEGORY --subject "..." --commits HASH --background "..." --changes "..."`
2. For public repos: `doc-append CHANGELOG.md --category CATEGORY --subject "..." --background "..." --changes "..."` (no `--commits`)
3. `git add docs/ README.md CHANGELOG.md`
4. Wait for user verification; emit `<<WORKFLOW_USER_VERIFIED: <reason>>>` and invoke `commit-push`.
