"use strict";
// hooks/bash-guard/forbidden-literals.js — SSOT for the forbidden-literal set.
//
// The approved set is the "Prohibited literal / Form" table in rules/shell-commands.md,
// which lists `&&` and NOT `||`, so `||` and background `&` are absent here on purpose:
// code must not enforce a rule the discipline document never stated. Ten machine ids fold
// onto the table's seven human rows via `row` (an index into DOC_ROWS); the generator
// bin/print-forbidden-literals stamps the document from these two structures.
// Detection reads the IR and analysisOf(ir) only — never a regex over raw command text.

const DOC_ROWS = Object.freeze([
  "`&&` / `;` | command chaining",
  "`\\|` | pipe",
  "`` ` `` / `$(...)` | command substitution, variable capture",
  "`{ ... }` | grouping",
  "`<<` | heredoc",
  "`>` / `>>` | redirect",
  "`FOO=1 BAR=2 cmd` | leading environment-variable prefixes",
]);

// Order is the document's row order; cases-not-forbidden.sh F2 pins it exactly.
const FORBIDDEN_LITERALS = Object.freeze([
  Object.freeze({ id: "chain-and", literal: "&&", row: 0 }),
  Object.freeze({ id: "chain-semicolon", literal: ";", row: 0 }),
  Object.freeze({ id: "pipe", literal: "|", row: 1 }),
  Object.freeze({ id: "backtick", literal: "`", row: 2 }),
  Object.freeze({ id: "cmd-subst", literal: "$(...)", row: 2 }),
  Object.freeze({ id: "brace-group", literal: "{ ... }", row: 3 }),
  Object.freeze({ id: "heredoc", literal: "<<", row: 4 }),
  Object.freeze({ id: "redirect-out", literal: ">", row: 5 }),
  Object.freeze({ id: "redirect-append", literal: ">>", row: 5 }),
  Object.freeze({ id: "env-prefix", literal: "FOO=1 cmd", row: 6 }),
]);

const LITERAL_IDS = Object.freeze(FORBIDDEN_LITERALS.map((e) => e.id));

function literalById(id) {
  return FORBIDDEN_LITERALS.find((e) => e.id === id) || null;
}

module.exports = { FORBIDDEN_LITERALS, DOC_ROWS, LITERAL_IDS, literalById };
