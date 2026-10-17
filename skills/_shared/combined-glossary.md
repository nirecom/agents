# Combined Glossary

SSOT for how writers and reviewers use the combined glossary: the agreed terms of the project, so every artifact names one concept with one word.

**Source.** The combined glossary is the main worktree's `docs/glossary-user*.md` and `docs/glossary-internal*.md` (the main worktree is the first line of `git worktree list`; read it there, never the linked worktree's copy) plus the `## Glossary` table of the session intent.md (the intent glossary). In a codex prompt the file part arrives as the delimited combined glossary data and the intent glossary sits in the intent context.

**Missing sides.** When one side is missing, use the other; when both are empty, this fragment asks nothing.

**Category.** The category values (user / internal / session) and their meaning are owned by `rules/docs/glossary.md`.

**Referencing.** Outline and detail plans reference the intent glossary by term; never copy its table or definitions into the plan.

## Writer directives

- Use every glossary term with its exact spelling, and only in the meaning its definition gives.
- Never substitute a synonym, a rewording, or a case, hyphen or plural variant of a glossary term.
- When the work needs a concept the glossary lacks, name the new term explicitly as a glossary candidate instead of silently coining it.

## Reviewer directives

- Check the artifact against each glossary term's definition, and raise a concern for every synonym, rewording or spelling variant (case, hyphen, plural) that stands in for a glossary term.
- Raise a concern for a glossary term used in a meaning its definition does not cover, and for a new term coined without being named as a glossary candidate.
