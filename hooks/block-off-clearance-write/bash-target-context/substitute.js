// hooks/block-off-clearance-write/bash-target-context/substitute.js
// substituteAssignments() — resolves `$NAME` / `${NAME}` inside a Bash write
// target against the same contiguous preceding assignment chain (variable
// splicing, e.g. `S=.workflow-off; … > <wf>/s1$S`). Split out of
// bash-target-context.js under the file-split HARD limit (rules/coding/
// file-split.md).
"use strict";

const VAR_REF_IN_TEXT_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;

// `$NAME` and `` `cmd` `` are symmetric members of one class — text the
// SHELL replaces before the write lands — so "unresolved expansion?" must
// ask about both (CPR-5). The substitution BODY is separately re-scanned as
// command text by ./bash-scan.js; this half is about the target it produces.
const EXPANSION_CHAR_RE = /[$`]/;

// An ANSI-C quoted segment `$'…'` is QUOTING, not an expansion — bash decodes
// it statically and never substitutes into it — but its leading `$` still
// matches EXPANSION_CHAR_RE, which would misclassify a fully static
// `$'<wf>/plain.txt'` target as dynamically-named. Removed only for the
// residual test; `text` itself keeps its ANSI-C form so the basename
// normalizer in ../../lib/protected-basenames.js can still decode it there.
const ANSI_C_SEGMENT_RE = /\$'(?:\\.|[^'])*'/g;
function withoutAnsiCSegments(text) {
  return String(text).replace(ANSI_C_SEGMENT_RE, "");
}

// Same assignment shape bash-scan.js / interpreter-scan.js already look for,
// including the pwsh `$env:NAME=` prefix (CPR-2 — one spelling of the lookup).
function lookupAssignedValue(assignText, varName) {
  if (typeof assignText !== "string" || assignText === "") return null;
  // `$ENV:`/`$Env:` are the same prefix — folded via the shared
  // PWSH_ENV_PREFIX so all three assignment lookups agree (CPR-2/CPR-5).
  const { PWSH_ENV_PREFIX } = require("../../lib/case-insensitive-literal");
  const re = new RegExp("(?:^|[\\s;&|]|\\$" + PWSH_ENV_PREFIX + ")" + varName + "=(\\S+)", "m");
  const m = re.exec(assignText);
  return m ? m[1] : null;
}

// substituteAssignments(text, assignText):
//   { text, substituted, unresolved }
// `unresolved` is true when a `$` survives substitution — the caller decides
// whether that is fail-closed material (it is, but only when the assignment
// chain mentions a protected name; `> $LOG` must stay approved).
function substituteAssignments(text, assignText) {
  if (typeof text !== "string") return { text: "", substituted: false, unresolved: false };
  if (!EXPANSION_CHAR_RE.test(text)) return { text, substituted: false, unresolved: false };
  let out = text;
  let substituted = false;
  for (let pass = 0; pass < 4 && out.includes("$"); pass++) {
    let changed = false;
    out = out.replace(VAR_REF_IN_TEXT_RE, (m, braced, bare) => {
      const value = lookupAssignedValue(assignText, braced || bare);
      if (value === null) return m;
      changed = true;
      substituted = true;
      return value;
    });
    if (!changed) break;
  }
  return {
    text: out,
    substituted,
    unresolved: EXPANSION_CHAR_RE.test(withoutAnsiCSegments(out)),
  };
}

module.exports = {
  substituteAssignments,
  EXPANSION_CHAR_RE,
};
