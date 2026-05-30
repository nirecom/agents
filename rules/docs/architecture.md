---
globs: "docs/architecture.md,docs/architecture/**/*.md"
---

## architecture.md Rules

- Document What/Why. How belongs in `ops.md`.
- Target size: <300 lines. When exceeded, split into `architecture/` directory; main file becomes `architecture/design.md`. Other split files use topical names (e.g. `risks.md`, `stacks.md`).
- `architecture/design.md`: same What/Why scope as `architecture.md`; unlimited size.
