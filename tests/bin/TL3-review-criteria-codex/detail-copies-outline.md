# Detail Plan

## Background

- Requirements: intent R1-R3.

## Stop Policy

- After round 3 the loop stops and asks the user to choose: continue, accept, or abandon.
- Automatic retry is forbidden at every round; only the user restarts a review.
- The stop is enforced in `bin/review-loop` by a round counter compared against the constant 3.

## Files to modify

- `bin/review-loop`: add a round counter; when it reaches 3, print the choice prompt and exit 0.

## Steps

1. Add the round counter and the stop at round 3.
2. Leave the concern ledger format unchanged.

## Tests

- `tests/bin/review-loop-stop.sh`: round 3 stops and prints the choice prompt; a failing review is reported, not retried.
