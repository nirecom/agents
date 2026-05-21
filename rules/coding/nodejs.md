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

#### TypeScript-specific (applies when .ts files are added)

- Enable `strict` mode in `tsconfig.json`.
- Use `unknown` instead of `any`; narrow with type guards.
