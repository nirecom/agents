---
paths:
  - "docs/glossary.md"
  - "docs/glossary-*.md"
---

# Glossary Entry Criteria

## Category

Give every term exactly one category: `user`, `internal`, or `session`.
`user`: a term the user sees directly — a skill name, a `.env` setting, a sentinel, a workflow step, a confirmation dialog.
`internal`: a term the user never sees but many components reference as a design concept.
`session`: a term used only inside one session's plans; record it in the intent glossary and never in a glossary file.
In code, keep the key and the value apart (`category: 'user'`); never coin an abbreviation for a category.

## What to list

List a term only when it meets the `user` or `internal` criterion.
Define a term used by a single subsystem once, in its owning document, and keep it out of the glossary (CPR-SSOT).

## Files

The category decides the file: `user` goes to `docs/glossary-user.md`, `internal` to `docs/glossary-internal.md`.
Keep `docs/glossary.md` as a short index that links both files; put no entries in it.
When a category file exceeds the HARD 500 lines, split it by alphabetical range into `docs/glossary-<category>-<from>-<to>.md`.
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
