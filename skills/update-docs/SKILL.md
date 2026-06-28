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

UD-1. **Gather recent changes**:
   - Run `git diff` and `git diff --cached` to capture uncommitted and staged changes (current session's work, not yet in git log)
   - Run `git log --oneline -20` for committed history
UD-2. **Read current docs**: Read all target docs files.
   - `README.md` (repo root) is required for all repos. **Create it first if missing — highest priority.**
     - Goal: make the reader think "I want to use this" — crisp features, "what it does for you"
     - Initial install/setup instructions go here, not in `ops.md`
   - `CHANGELOG.md` (repo root) for public repos. Create if missing (no manual seed needed — first run starts from here).
UD-3. **Identify gaps**: Compare git log against each document's content. Look for:
   - Unrecorded commits or phases
   - Architecture/design changes not yet documented
   - New incidents or bug fixes
   - Infrastructure or operational changes
   - Progress updates
   - `README.md`: Update when a user-visible feature is added or changed, install/usage steps shift, or an existing bullet no longer accurately reflects real behavior.
UD-4. **Propose updates**: For each file that needs updating, present:
   - Before drafting History/Changelog bullets: apply the language configured by `DOCS_LANG_HISTORY_PUBLIC` / `DOCS_LANG_HISTORY_PRIVATE` for history, `DOCS_LANG_CHANGELOG_PUBLIC` / `DOCS_LANG_CHANGELOG_PRIVATE` for changelog; routed by repo visibility
   - Which sections need changes and why
   - Specific additions or modifications
UD-5. **CONFIRM_DOCS gate** — check via Bash:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_DOCS on'`
   - stdout `ON` or `ERROR`: present the UD-4 proposal via `AskUserQuestion` and wait for approval before applying edits.
   - stdout `OFF`: apply the edits and continue to step UD-6 without waiting.
UD-6. **Propagate to parent docs**: If the project has a parent-level summary doc (e.g. an engineering hub), update it too. Skip for repo-local `docs/`.
   - Skip `infrastructure.md` — delegate to `/update-infrastructure` instead.
UD-7. **Commit separately**: If docs are in a separate repo, commit each repo independently

## Rules

- Follow the structure and content rules defined in `rules/docs.md`
- Follow `DOCS_LANG_HISTORY_*` / `DOCS_LANG_CHANGELOG_*` settings in `.env` for History/Changelog entry language
- Follow the gather → propose → confirm → apply cycle; the confirmation step is gated by `CONFIRM_DOCS` — when `off`, the proposal is shown but no AskUserQuestion is raised
- Compare git log against current docs to identify gaps

## Completion

After completing this skill, choose Path A or Path B based on `ENFORCE_WORKTREE`.

### Path A — ENFORCE_WORKTREE=on (mandatory)

UD-8. Complete delivery (Path A — `ENFORCE_WORKTREE=on` mandatory).

UD-8a. Append history bullets to `<worktree>/WORKTREE_NOTES.md` `## History Notes`. Replace `- (none)` on first append.
   - **MANDATORY when `closes_issues` is non-empty**: write one bullet per closed issue (matching the `closes_issues` count). `/worktree-end` Step WE-21 is the canonical writer of `docs/history.md` (Approach C, #690) and consumes these bullets via `compose-doc-append-entry --closes-issues-count N`. The CLI fail-fasts (non-zero exit) when `closes_issues > 0` AND `## History Notes` is absent / contains only `- (none)`.
   - When bullet count is below `closes_issues` count, the CLI emits a soft warning to stderr but proceeds.
UD-8b. For public repos: append user-facing bullets to `## Changelog Notes`. Replace `- (none)` on first append.
UD-8c. Do NOT write `docs/history.md` or `CHANGELOG.md` directly — deferred to `/worktree-end` Step WE-21 (single canonical writer for both files).
UD-8d. Stage: `git add docs/ README.md` (intentionally omits `CHANGELOG.md` and `docs/history.md`).
UD-8e. Commit gate is satisfied by `docs/` staged entries (architecture.md, ops.md, README.md, etc.).
UD-8f. Emit: `echo "<<WORKFLOW_MARK_STEP_docs_complete>>"` — satisfies the workflow gate.
UD-8g. Wait for user verification; emit `<<WORKFLOW_USER_VERIFIED: <reason>>>`.

### Path B — ENFORCE_WORKTREE=off

UD-9. Complete delivery (Path B — `ENFORCE_WORKTREE=off`).

UD-9a. Delegate history entry to doc-append-worker:
   `Agent({ subagent_type: "doc-append-worker", prompt: JSON.stringify({ mode: "history", category: CATEGORY, subject: "...", commits: "HASH", background: "...", changes: "...", cwd: CWD, agents_config_dir: AGENTS_CONFIG_DIR, artifact_dir: PLANS_DIR }) })`
UD-9b. For public repos — delegate changelog entry to doc-append-worker:
   `Agent({ subagent_type: "doc-append-worker", prompt: JSON.stringify({ mode: "changelog", category: CATEGORY, subject: "...", background: "...", changes: "...", cwd: CWD, agents_config_dir: AGENTS_CONFIG_DIR, artifact_dir: PLANS_DIR }) })`
   On `failed` status: surface `artifact_path` to the user and stop.
UD-9c. `git add docs/ README.md CHANGELOG.md`
UD-9d. Emit: `echo "<<WORKFLOW_MARK_STEP_docs_complete>>"` — satisfies the workflow gate.
UD-9e. Wait for user verification; emit `<<WORKFLOW_USER_VERIFIED: <reason>>>`.
