### FEATURE: Add CHANGELOG.md — automated via /update-docs (2026-05-04)
Background: update-docs now writes to both docs/history.md (internal) and CHANGELOG.md (user-facing) in one run.
Changes: CHANGELOG.md is now automatically maintained. Each update-docs run appends a user-facing summary entry. doc-append accepts --commits as optional, enabling date-only headers suited for a public changelog.
