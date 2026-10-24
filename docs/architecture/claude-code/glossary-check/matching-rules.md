# Glossary Drift Matching Rules

What `bin/check-glossary-drift` counts as drift (#2763). The summary and the check itself are in
[glossary-check.md](../glossary-check.md#matching-rules); the code is `bin/lib/glossary-drift/`.
Examples use fictional identifiers (`FOO_BARS_DIR`): code spans are checked too, so a variant of a
real identifier written here would be drift in this file.

## Two contexts

An identifier and an English word follow different spelling rules. An identifier's naming
convention (case, `_` or `-`) belongs to the language it lives in, while a prose term is spelled as
the glossary spells it. Every word is therefore matched in one of two contexts.

**`identifier context`** covers:

- The contents of a markdown code span, matched as a layer of its own (`extractIdentifierText`).
- A chunk without whitespace that holds `_`, `=`, `$`, `{` or `}`, such as `FOO_BAR=1`, `${FOO_DIR}`, or each element of `{A,B}`.
- A fixed-format line, such as a `Tags:` line. `FIXED_FORMAT_LINE_RE` in `context.js` is the only list of these.
- Fixed schema headings such as `## Steps`. The matcher keeps no list of them: they spell their words correctly, so the heading tolerance below gives the same result. Reviewers read them as `identifier context`.

**Capital words.** A run of capital words (two or more characters, `[A-Z][A-Z0-9]+`) is matched first
as an identifier. When no identifier term fits, it is matched only against terms spelled in capitals
at the same positions (`RTK`, `WF-CODE`), then judged by the prose rules. It never meets a term
spelled in lower case, so a capital `WORKFLOW` is no variant of the one-word term.

## Identifier context

Each identifier has two keys:

- Raw key: lower case, separators removed.
- Folded key: the raw key with each word singularized.

Against `FOO_BARS_DIR`:

| Window | Result | Why |
|---|---|---|
| `foo_bars_dir`, `FOO-BARS-DIR`, `FOOBARSDIR` | no drift | same raw key, no whitespace: a naming convention |
| `FOO_BAR_DIR` | drift | the folded keys meet but the raw keys differ: a word form |
| `foo bars dir` | drift | split at whitespace |
| `fooBarsDir` | not matched | camelCase and PascalCase may name it in another language |

## Prose context

Tolerated:

- A regular plural of the last word (`glossary drifts`).
- A capital first letter on the first word of a sentence.
- A capital first letter on every word of a heading line or a table header row (`## Glossary Drifts`).

Still drift:

- Case mid-sentence (`the Glossary drift`), and a table body row's first cell.
- A hyphen for a space or a space for a hyphen, heading lines included. A hyphen variant is matched on the separator-stripped form, so splitting a one-word term (`work-flow`) or joining a multi-word term (`glossarydrift`) counts.
- An identifier term split into English words, written without backticks.

A whitespace break counts only where the term itself has a word break: `presentation-turn` is a variant of `presentation turn`, but `set up` is ordinary English, not a variant of `setup`.

**Lowercase acronym in code comment.** In a comment line of a code file, a term spelled wholly in
capitals (`RTK`, `WF-CODE`) and written wholly in lower case with the same separators is not drift:
the lower-case form there is the command or value name. Markdown does not get this rule, because
markdown marks an identifier with backticks and a bare lower-case word stays prose.

## Backticks in markdown prose

Writers put every identifier in markdown prose in backticks, spelled exactly. Only the LLM reviewers
check a missing backtick, as an untagged LOW concern: a correctly spelled identifier outside backticks
changes no meaning, and no deterministic rule can tell a command name from the English word.

## Term set

`identifierSpellings(terms)` in `terms.js` is the one function that picks the terms matched as
identifiers; today those are the terms holding `_`. A later Identifier field on a glossary entry is
meant to feed it, without touching the matcher.

Plurals are matched by suffix rules in `hooks/lib/glossary-term.js`: `-ies`, `-es` after `s` / `x` / `z` / `ch` / `sh`, `-s`, with `-us` / `-sis` / `-ss` singulars kept whole (`statuses` → `status`, `analyses` → `analysis`) and acronym plurals (`GPUs`) dropping their `s`. `-ves`, `-oes` (`echoes`), irregular plurals (`indices`) and `-us` plurals (`menus`) are not matched: a missed variant costs one review miss, while a looser stem match would flag derived words (`tester`, `gating`).

Terms that share a separator-stripped form (`workflow`, `work flow`) are all candidates. A variant goes to the one whose word breaks admit its whitespace breaks and whose separators differ least from its own, ties broken by sorted order.

## Known false positives

Resolve these through the accept path:

- A proper noun that capitalizes a term mid-sentence (`AWS Step Functions`), or put it in backticks.
- Ordinary English that spells out an identifier term's words in order, such as the words foo, bars and dir against `FOO_BARS_DIR`.
- A distinct identifier that differs from an identifier term only by a plural word.
