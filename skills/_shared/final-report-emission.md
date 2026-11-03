# Final Report Emission Scope

SSOT for what the Final Report emits verbatim and what `CONV_LANG` may translate.
Background: the Stop guard matches the headings literally and the compressed notes sections carry the only pointer to the full finding text — translating either breaks the close.

## Output scope

Write the renderer's stdout into your next assistant text; never leave it only in the tool result — the Stop guard reads assistant text, not tool output.
Emit it as-is: no preamble, no summarization, no section reordering or merging, no rewrapping.
When a Stop block reason embeds the rendered Final Report, emit that embed the same way.
Put nothing after the report in the same message; any other text goes in a separate message.
After a Stop block on an emitted report, output only the corrected report (no preamble, apology, or explanation).

## Verbatim — never translated

- The 13 section headings and the `## Final Report — <session-id>` header (checked literally in English by `hooks/stop-final-report-guard.js`; translating them blocks Stop).
- Every env-derived deterministic field: PR number / title / URL / state, branch name, paths, dates, SHAs, issue numbers, sentinel literals.
- `severity:high` full-text entries — reproduction steps and grep evidence stay in their original language; technical accuracy outranks language consistency.
- The `#N ` / `[issue-TBD] ` head of every notes entry line.
- Inside the backup pointer line `- (…; full text: <path>)`: the numeric counts and the path after `full text:` stay unchanged.

## CONV_LANG-translatable

Only the free-text prose of the compressed Bugs Found / Related Tasks / Next Tasks sections: the title-line text, and the prose words of the backup pointer line.

Retrieve with `bash "$AGENTS_MAIN_ROOT/bin/get-config-var" CONV_LANG`. Empty or `english` → translate nothing.
