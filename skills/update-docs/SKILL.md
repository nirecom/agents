---
name: update-docs
description: Update all project documentation to reflect recent changes
model: sonnet
effort: low
---

Update all project documentation to reflect recent changes.

Docs directory: `docs/` within the current project root.
Target files: all `.md` files in `docs/` that already exist, plus `README.md` in the project root.

**llama-swap additional**: when `config.yaml` changes, also update in-repo `model-annotations.yaml` and `optimization-history.md`.

## Procedure

1. **Gather recent changes**:
   - Run `git diff` and `git diff --cached` to capture uncommitted and staged changes (current session's work, not yet in git log)
   - Run `git log --oneline -20` for committed history
2. **Read current docs**: Read all target docs files.
   - Always include the root `README.md` in this read pass when the project has one — it is a target file (see header) and sits outside `docs/`, making it easy to miss.
3. **Identify gaps**: Compare git log against each document's content. Look for:
   - Unrecorded commits or phases
   - Architecture/design changes not yet documented
   - New incidents or bug fixes
   - Infrastructure or operational changes
   - Progress updates
   - `README.md` goal: make the reader think "I want to use this." Write key features in
     crisp, abstract terms — the "what it does for you", not implementation details.
     Update when: a user-visible feature is added or changed, install/usage steps shift,
     or an existing bullet no longer accurately reflects real behavior.
4. **Propose updates**: For each file that needs updating, present:
   - Which sections need changes and why
   - Specific additions or modifications
5. **Apply after confirmation**: Edit files only after user approval
6. **Propagate to parent docs**: If the project has a parent-level summary doc (e.g. an engineering hub), update it too. Skip for repo-local `docs/`.
7. **Commit separately**: If docs are in a separate repo, commit each repo independently

## Rules

- Follow the structure and content rules defined in `rules/docs-convention.md`
- Follow the gather → propose → confirm → apply cycle (never write without user confirmation)
- Compare git log against current docs to identify gaps

## Completion

After completing this skill, stage the updated doc files:
`git add docs/ README.md`
(If the project has no `README.md`, omit it — `git add` on a non-existent path errors.)
The commit gate detects staged docs/ or root `*.md` changes as evidence of completion.
Docs updates are mandatory for every task — there is no skip path.
