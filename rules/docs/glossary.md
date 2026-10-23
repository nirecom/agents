---
paths:
  - "docs/glossary.md"
  - "docs/glossary-*.md"
---

# Glossary Entry Criteria

## What's a glossary

The glossary defines terms used across multiple subsystems, so every artifact uses one wording per concept.
Never list a term used in only one subsystem.
Add an entry only by glossary promotion of an intent glossary row of the same category.

## Category

`user`: a keyword the user sees — a skill name, a `.env` key, a workflow step.
`internal`: a key design concept the user never sees.
`session`: unifies wording within one session only; never promoted.

## Files

The category decides the file: `user` goes to `docs/glossary-user.md`, `internal` to `docs/glossary-internal.md`.
Keep `docs/glossary.md` as a short index that links both files; put no entries in it.
When a category file exceeds the docs HARD of [../coding/file-split.md](../coding/file-split.md#size-limits), split it by alphabetical range into `docs/glossary-<category>-<from>-<to>.md`.
Write `<from>` and `<to>` as single lowercase letters; both ends are inclusive.
Make the ranges of one category non-overlapping and together cover a to z.
After a split, delete the unsplit category file.
Place a term in the file whose range holds the first letter of the lowercased term.
Place a term whose first character is not a to z in the file whose range starts at a.

## Entry form

Write each entry as a `### <term>` heading, one `- **Definition**:` line, and one `- **Related**:` line.
Keep the definition to 1-2 lines; state what the term is and where the reader meets it.
Expand an abbreviation inside the definition; write no Full name or Level line.
Never state file placement or storage paths in the definition.
Give Related exactly one Markdown link, to the document that owns the term; never link an issue URL.
Sort all entries alphabetically, case-insensitive (lowercased, code-unit order).
Put no section headings in a glossary file other than the H1.

## Enforcement

The glossary gate (`bin/review-doc-glossary`) enforces the entry form, the order, and the file ranges.
The review_docs step checks that each added or moved term carries the right category.
