---
globs: "**/*.js,**/*.ts,**/*.mjs,**/*.cjs,**/package.json,**/.nvmrc,**/.node-version"
---

## Node.js

- Do not install Node.js directly. Use a version manager:
  - **Windows (PowerShell):** `fnm` (`fnm use` / `.node-version` auto-detection)
  - **WSL2 / macOS / Linux:** `nvm` (`nvm use` / `.nvmrc` auto-detection)

### Review-relevant invariants (already followed in this repo)

- Module system: match the surrounding module system; do not mix CommonJS and ESM within one package.
- `const` by default; `let` only when reassignment is needed; `var` is forbidden.
- `===`/`!==` always; `==`/`!=` is forbidden except for the deliberate `x == null` pattern.
- Prefer small, focused modules.

#### Windows path normalization

- External inputs (hook payloads, Bash tool `cwd`, CLI args, env vars) may arrive as POSIX drive-letter paths (e.g., `/c/git/agents` from Git Bash / MSYS2). Node.js file and process APIs (`fs.*`, `spawnSync cwd`, `path.resolve`) require Windows-form paths on Windows and will fail with ENOENT on the POSIX form.
- Normalize any externally-sourced path before passing it to a file or process API — convert `/c/foo` → `C:\foo` (a no-op on POSIX). Apply symmetric treatment: if one code path normalizes, all code paths receiving the same class of input must normalize too (CPR-5).

#### TypeScript-specific (applies when .ts files are added)

- Enable `strict` mode in `tsconfig.json`.
- Use `unknown` instead of `any`; narrow with type guards.
