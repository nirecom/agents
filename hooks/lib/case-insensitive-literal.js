// hooks/lib/case-insensitive-literal.js
// Build a case-insensitive regex fragment for a literal, WITHOUT the `i` flag.
//
// #1780 H-4: several scanners have to match names that the real runtime treats
// case-insensitively (Windows executable lookup — `Node -e`, `BASH -c`,
// `PwSh -Command`; PowerShell parameter and cmdlet names; the `$env:` scope
// prefix) side by side, in the SAME regex, with names the runtime treats
// case-sensitively (POSIX short flags — `sh -c` is "run this command" while
// `sh -C` is noclobber; JavaScript / Python identifiers such as
// `console.log`, `readFileSync`, `os.environ`; shell variable names).
//
// JavaScript has no inline scoped flags — `i` applies to the whole pattern — so
// slapping `i` on such a regex would silently make the case-SENSITIVE half
// case-insensitive too, which is a different bug in the opposite direction
// (spurious matches, and for a fail-closed gate that means spurious blocks).
// Expanding only the case-insensitive literals into explicit [Aa] classes keeps
// each half faithful to its own language's rules and, more importantly, keeps
// the choice VISIBLE at every call site (CPR-8: no implicit assumption).
"use strict";

// ci("node") -> "[Nn][Oo][Dd][Ee]"; non-letters are passed through escaped so
// the result is safe to interpolate into a String.raw pattern.
function ci(literal) {
  return String(literal)
    .split("")
    .map((ch) => {
      const lo = ch.toLowerCase();
      const up = ch.toUpperCase();
      if (lo !== up) return `[${lo}${up}]`;
      return ch.replace(/[.*+?^${}()|[\]\\/-]/g, "\\$&");
    })
    .join("");
}

// The PowerShell environment-variable scope prefix, as a regex fragment.
// `$ENV:PATH`, `$Env:PATH` and `$env:PATH` are the same variable, so every
// scanner that recognizes this prefix must recognize all of its casings — and
// must recognize the SAME set, or one hook's "sanctioned inert token" becomes
// another's "unknown interpolation" (#1780 H-4). Kept here, next to ci(),
// because it is the one such literal shared across hooks (CPR-2).
const PWSH_ENV_PREFIX = ci("env") + ":";

module.exports = { ci, PWSH_ENV_PREFIX };
