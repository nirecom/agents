---
name: update-docs
description: Update all project documentation to reflect recent changes
model: sonnet
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

After completing this skill:
1. Append to `docs/history.md` (internal, detailed):
   `doc-append docs/history.md --category CATEGORY --subject "..." --date YYYY-MM-DD --commits HASH --background "..." --changes "..."`
2. Append to `CHANGELOG.md` (external, user-facing summary — omit `--commits`):
   `doc-append CHANGELOG.md --category CATEGORY --subject "..." --date YYYY-MM-DD --background "..." --changes "..."`
   `--background` = one sentence on context; `--changes` = what changed from a user perspective (no internal refs).
   For public repos only. Skip if the repo is private.
3. Stage the updated doc files: `git add docs/ README.md CHANGELOG.md`
   `README.md` is required for all repos — create it if it does not exist before staging.
   The commit gate detects staged docs/ or root `*.md` changes as evidence of completion.
   Docs updates are mandatory for every task — there is no skip path.
4. Wait for the user to verify the changes, then run `echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"` and invoke `commit-push` via the Skill tool.
