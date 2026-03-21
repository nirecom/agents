# Documentation Convention

## Standard Files

| File | Role | Target size | Created |
|------|------|-------------|---------|
| `architecture.md` | What/Why of design decisions (not How — How belongs in `ops.md`) | Unlimited (split into `architecture/` OK) | Always |
| `todo.md` | Current work pointer — reading from top tells you what to do now | <100 lines | Always |
| `history.md` | Completed work with why (background, incidents, decisions) — append-only | Unlimited | On first completion |
| `ops.md` | Operational procedures with actual commands | Unlimited | On demand |
| `instruction.md` | **SSOT** for physical machines, network, Docker stacks, ports, and cloud resources per stack/host. Other docs must reference this — never duplicate host placements. | Unlimited | Always (in `ai-specs`) |

Do not use `progress.md` or standalone `roadmap.md` — status tracking belongs in `todo.md`,
completed details in `history.md`, future design specs in `architecture/roadmap.md`.

## Progressive Disclosure (Cascade)

Same-named files at different hierarchy levels provide the same kind of information
scoped to that level. Upper levels contain **summary + pointers**, not duplicated content.

| Level | Example | Content |
|-------|---------|---------|
| Hub of hubs | `engineering/architecture.md` | One-line per project → links to project `architecture.md` |
| Project hub | `{project}/architecture.md` | Index or flat design doc |
| Detail | `{project}/architecture/overview.md` | Full design detail |

## Doc Location and Commit Hook

The `check-docs-updated` hook enforces that documentation is updated alongside code.
It checks two locations in priority order:

1. **Local**: `docs/` or any `.md` file staged in the same repo
2. **Sibling ai-specs**: `../ai-specs` — searches for a directory matching the repo name

If a project's docs live in `ai-specs` (not in the repo itself), the hook will
automatically find them — no configuration file needed. The repo name must match
the directory name under `ai-specs/` (e.g., repo `llm-infra-check` →
`ai-specs/**/llm-infra-check/`).

When committing code changes, ensure the corresponding docs in `ai-specs` have
staged or unstaged changes, otherwise the commit will be blocked.

## Content Rules

- `todo.md`: Current Work section first. Status Summary has incomplete phases only (completed → `history.md`).
  When updating todo.md after completing implementation work, add a **user verification step** as the next action item. The phase/task stays in Current Work with "Verifying" status until the user confirms completion. Do not move it to `history.md` until verification passes.
- `history.md`: Record completed work with **why** (background, incidents, migration rationale) — not just what was done. Use `###` section per entry (not table — long text is unreadable in tables). Commit hashes only (7 chars, no GitHub links). This prevents re-litigating past decisions in future conversations. Format:
  ```
  ### Subject (commits)
  Background: ...
  Changes: ...
  ```
  Incident entries use `Cause:` / `Fix:` instead of `Background:` / `Changes:`.
  If `history.md` is in legacy table format, convert it using `~/dotfiles/bin/convert-history-table.py`. **Always** present the converted output to the user for review before overwriting.
- `instruction.md`: Authoritative source for host specs, network topology, Docker stack composition, port allocation, and cloud resources. When adding or moving a service, update `instruction.md` first — downstream docs (`architecture.md`, `ops.md`) reference it. Use the `/update-instruction` skill to keep it aligned with infrastructure changes.
- `architecture.md`: Document What/Why. How belongs in `ops.md`
- `ops.md`: Keep procedures actionable with real commands
- Do not duplicate content across documents — cross-reference instead
- Match the existing language style of each file
