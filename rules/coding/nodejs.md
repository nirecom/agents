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

#### Windows: POSIX path normalization

- `toolInput.cwd`, env vars, and CLI args may deliver paths in POSIX drive-letter form (`/c/...` from Git Bash / MSYS2); Node.js `fs.*` and `spawnSync cwd` fail with ENOENT on this form — normalize via `toWindowsPath` (no-op on POSIX) before every file or process API call.
- Apply at every call site that accepts the same path input class; omitting one site while normalizing another is a CPR-5 violation.

#### TypeScript-specific (applies when .ts files are added)

- Enable `strict` mode in `tsconfig.json`.
- Use `unknown` instead of `any`; narrow with type guards.
