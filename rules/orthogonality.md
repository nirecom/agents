# Orthogonality

## .env / .env.example Orthogonality

Whenever a variable is added, removed, or renamed in `.env`, update `.env.example` in
the same change, and vice versa:
- `.env` — real secrets, never committed.
- `.env.example` — placeholder values that document all required variables.

## Cross-Platform Orthogonality

- When adding or modifying functionality for one platform (e.g., `install/win/`), apply the equivalent change to other platforms (e.g., `install/linux/`) unless there is a platform-specific reason not to.

## Naming Orthogonality

- When adding new files that belong to an existing convention (hooks, markers, config), follow the established naming pattern. Check existing counterparts before choosing a name.
