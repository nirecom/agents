# Final Report Emission Scope

SSOT for what the Final Report emits verbatim and what `CONV_LANG` may translate.
Background: the Stop guard matches the headings literally and the compressed notes sections carry the only pointer to the full finding text — translating either breaks the close.

## Output scope

Emit the renderer's stdout as-is: no preamble, no summarization, no section reordering or merging, no rewrapping.

## Verbatim — never translated

- The 13 section headings and the `## Final Report — <session-id>` header (checked literally in English by `hooks/stop-final-report-guard.js`; translating them blocks Stop).
- Every env-derived deterministic field: PR number / title / URL / state, branch name, paths, dates, SHAs, issue numbers, sentinel literals.
- `severity:high` full-text entries — reproduction steps and grep evidence stay in their original language; technical accuracy outranks language consistency.
- Inside the summary line `- (compressed: N entries — title line only; full text: <path>)`: the numeric counts and the path after `full text:` stay unchanged.

## CONV_LANG-translatable

Only the free-text prose of the compressed Bugs Found / Related Tasks / Next Tasks sections: the title-line text, and the prose words of the summary line.

Retrieve with `bash "$AGENTS_CONFIG_DIR/bin/get-config-var" CONV_LANG`. Empty or `english` → translate nothing.
