# Detail Plan

## Background

- Requirements: intent R1-R3. Stop policy: outline `## Stop Policy`.

## Files to modify

- `bin/review-loop`: add a round counter; when it reaches 3, print the choice prompt and exit 0.
- `bin/review-loop`: when a review exits non-zero, retry it automatically up to 2 times with a 10 second back-off before reporting the failure.

## Steps

1. Add the round counter and the stop at round 3.
2. Add the automatic retry with back-off for failed reviews.
3. Leave the concern ledger format unchanged.

## Tests

- `tests/bin/review-loop-stop.sh`: round 3 stops and prints the choice prompt.
- `tests/bin/review-loop-retry.sh`: a failing review is retried twice, then reported.
