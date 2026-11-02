# Course-Correction Lookup Mode

Criterion: artifact–conversation drift, the audit role of `agents/supervisor-audit.md` (#708).

## Inputs

The prompt carries the transcript path, `--session`, `--format` and the `review-loop-upstream list` rows.

## Per row

- Search the transcript for a user statement made after the upstream plan step's approval that directed the deviation the row's quote and defect describe.
- When found, take the `uuid` of that user entry.
- Record it: `bash "$AGENTS_MAIN_ROOT/bin/review-loop-upstream" decide --session S --format F --id C<N> --text-hash H --choice course-correction --transcript P --uuid U --reason "<1 line>"`.
- Never copy the user's words yourself; the CLI extracts the record.
- When none is found, record nothing.

## Reply

One line per row: `C<N>: recorded <path>` or `C<N>: not-found`.
