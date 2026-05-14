# Documentation Convention

## Standard Files

Standard docs live under `docs/` within each repository, except `README.md`.
`docs/` may be a symlink managed by another repo — check before editing.

| File | Role | Target size | Created |
|------|------|-------------|---------|
| `README.md` | Repo's project pitch and entry point — what it does, install, usage, configuration. Write initial install/setup instructions here first. | Compact | Always |
| `CHANGELOG.md` | User-facing release log — what changed and why it matters to users. Written by `/update-docs` via `doc-append CHANGELOG.md` (no `--commits`). Public repos only. | Append-only | Public repos |
| `overview.md` | Highest-level description of a project or directory — vision, goals, and overall shape. Most abstract document in its location. | Compact | Large projects only |
| `architecture.md` | What/Why of design decisions (not How — How belongs in `ops.md`). When split into `architecture/`, the main file is `architecture/design.md`. | <300 lines (split into `architecture/` when exceeded) | Always |
| `architecture/design.md` | Main content file when `architecture.md` is split. Same What/Why scope. Other split files use topical names (e.g. `risks.md`, `stacks.md`). | Unlimited | When `architecture.md` exceeds 300 lines |
| `roadmap.md` | Project-wide goals, milestones, and direction | Compact | Optional |
| `todo.md` | Current work pointer — reading from top tells you what to do now | <100 lines | Always |
| `history.md` | Completed work with why (background, incidents, decisions) — append-only | <500 lines warn / <800 lines hard (rotate when exceeded) | On first completion |
| `ops.md` | Day-to-day operations and procedures too detailed for README.md. Initial install instructions belong in README.md, not here. | Unlimited | On demand |
| `infrastructure.md` | SSOT for physical machines, network, Docker stacks, ports, and cloud resources per stack/host. Other docs must reference this — never duplicate host placements. Path is defined in `CLAUDE.local.md`. | Unlimited | Always |

## Content Rules

**Append-only**: Do NOT use Edit tool for `history.md` or `CHANGELOG.md` — use `doc-append` CLI instead. See [docs-convention/history-rules.md](docs-convention/history-rules.md) for tool reference and rotation thresholds.

- `overview.md`: Project vision and overall shape. Most abstract document in its directory. Does not duplicate `architecture.md` design decisions.
- `infrastructure.md`: When adding or moving a service, update `infrastructure.md` first — downstream docs reference it. Use `/update-infrastructure` skill to keep it aligned.
- `ops.md`: Day-to-day operations and complex procedures. Never write initial install steps here — those belong in README.md.
- Do not duplicate content across documents — cross-reference instead.

## Progressive Disclosure (Cascade)

Same-named files at different hierarchy levels provide the same kind of information
scoped to that level. Upper levels contain **summary + pointers**, not duplicated content.
All standard doc types (`todo.md`, `history.md`, `ops.md`) follow the same cascade —
`architecture.md` is shown as an example below.

| Level | Example | Content |
|-------|---------|---------|
| Hub of hubs | `engineering/architecture.md` | One-line per project → links to project `architecture.md` |
| Project hub | `{project}/architecture.md` | Index or flat design doc |
| Detail | `{project}/architecture/design.md` | Full design detail |

When updating a project-level doc in ai-specs, also update its parent-level counterpart
(e.g. `langchain/todo.md` → `engineering/todo.md`).
Repo-local `docs/` has no parent level — propagation is not needed.

## Planning Pipeline Artifacts

Session planning artifacts (`<session-id>-intent.md`, `-outline.md`, `-detail.md` under `~/.workflow-plans/`) are governed by their own stage-specific obligations:
- **Intent stage:** captures scope, constraints, and timeline/dependency context only — does not decide delivery plan. When `CONFIRM_OUTLINE=off`, also captures delivery plan direction (see `skills/clarify-intent/SKILL.md`).
- **Outline stage:** each approach must declare a **Delivery plan** field (triage rationale / execution order / split policy). When `CONFIRM_DETAIL=off`, the delivery plan must be finalized here. See `skills/make-outline-plan/SKILL.md`.
- **Detail stage:** opens with **Delivery plan** first (importance-first section ordering). When outline carried a delivery plan forward, it is surfaced to the main conversation before the planner runs. See `skills/make-detail-plan/SKILL.md` and `agents/detail-planner.md`.

## Sub-rules (path-scoped via `globs:`)

Loaded automatically when editing the relevant file type; also readable on demand:

- [docs-convention/history-rules.md](docs-convention/history-rules.md) — history.md format, append-only tools, and rotation thresholds
- [docs-convention/todo.md](docs-convention/todo.md) — todo.md structure and user verification flow
- [docs-convention/changelog.md](docs-convention/changelog.md) — CHANGELOG.md user-facing scope rules
- [docs-convention/architecture.md](docs-convention/architecture.md) — architecture.md What/Why scope and 300-line split rule
- [docs-convention/readme.md](docs-convention/readme.md) — README.md entry point rules
- [docs-convention/env-example.md](docs-convention/env-example.md) — .env.example variable comment format
