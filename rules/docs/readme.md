---
paths:
  - "README.md"
---

## README.md Rules

- Project entry point: What / Install / Usage / Configuration.
- **Initial install/setup instructions must go here, not in `ops.md`.**
- Delegate internals to `architecture.md` and detailed procedures to `ops.md` — do not duplicate. Keep concise — link to `docs/` for details.
- my-specs-repo projects: Lives in the source repo root, not in my-specs-repo.

## Section Importance Order

- Order sections most-important first: What, Quickstart, Usage, Configuration, Reference, Contributing. A README may omit a section but must not present them out of order.
- Exclude implementation details (internal architecture, code walkthroughs, design rationale) — reference `architecture.md` / `docs/` instead.
- The block below is the SSOT parsed by `bin/review-doc-heading-order` (the `review_docs` step's heading gate). One class per line in importance order; a README heading matches a class when its lowercased text contains one of that class's aliases. Editing the order or aliases here re-defines the gate.

<!-- readme-section-order:start -->
<!-- 1 what: what, what it does, about, overview, why -->
<!-- 2 quickstart: quickstart, quick start, install, installation, setup, getting started -->
<!-- 3 usage: usage, how to use, examples -->
<!-- 4 configuration: configuration, config, settings, options -->
<!-- 5 reference: reference, advanced, architecture, details, internals -->
<!-- 6 contributing: contributing, development, license, licence -->
<!-- readme-section-order:end -->
