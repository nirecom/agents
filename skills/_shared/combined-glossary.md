# Combined Glossary

SSOT for how writers and reviewers use the combined glossary: the agreed terms of the project, so every artifact names one concept with one word.

**Source.** The combined glossary is the main worktree's `docs/glossary/*.md` (the main worktree is the first line of `git worktree list`; read it there, never the linked worktree's copy) plus the `## Glossary` table of the session intent.md (the intent glossary). In a codex prompt the file part arrives as the delimited combined glossary data and the intent glossary sits in the intent context.

**Missing sides.** When one side is missing, use the other; when both are empty, this fragment asks nothing.

**Category.** The category values (user / internal / session) and their meaning are owned by `rules/docs/glossary.md`.

**Deterministic check.** `bin/check-glossary-drift` flags the spelling variants that the matching rules (`docs/architecture/claude-code/glossary-check.md#matching-rules`) count as drift; run it and resolve its findings per `skills/_shared/glossary-drift-check.md`.

**Referencing.** Outline and detail plans reference the intent glossary by term; never copy its table or definitions into the plan.

## Writer directives

- Use every glossary term with its exact spelling, and only in the meaning its definition gives.
- Never substitute a synonym, a rewording, or a spelling variant that the matching rules (`docs/architecture/claude-code/glossary-check.md#matching-rules`) count as drift.
- In markdown prose, wrap every identifier in backticks and spell it exactly as the identifier is written.
- When the work needs a concept the glossary lacks, name the new term explicitly as a glossary candidate instead of silently coining it.

## Reviewer directives

- Check the artifact against each glossary term's definition, and raise a concern for every synonym, rewording, or spelling variant the matching rules (`docs/architecture/claude-code/glossary-check.md#matching-rules`) count as drift that stands in for a glossary term.
- Tell `identifier context` from `prose context` by that section before raising a spelling-variant concern.
- A generic word that is part of a multi-word term (a lone `step`) is no rewording of that term unless it names the term's concept.
- Never map a Japanese expression to a glossary term.
- In markdown prose, an identifier written without backticks (a term holding `_`, or a command name or value spelled like a term) gets an untagged LOW concern, with no `[glossary-drift ...]` tag.
- Raise a misspelled identifier as a glossary-drift concern, backticked or not.
- Raise a concern for a glossary term used in a meaning its definition does not cover, and for a new term coined without being named as a glossary candidate.
- Start the text of every such glossary-drift concern with the tag `[glossary-drift term=<term>]`, right after `[SEV]` (anchored form: at the start of the field after `ref|path#anchor|cat|`), never at line start, where the parser drops it.
