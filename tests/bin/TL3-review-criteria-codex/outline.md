# Outline

## Stop Policy

- After round 3 the loop stops and asks the user to choose: continue, accept, or abandon.
- Automatic retry is forbidden at every round; only the user restarts a review.
- The stop is enforced in `bin/review-loop` by a round counter compared against the constant 3.

## Ledger

- The concern ledger keeps its current pipe-separated format; no column is added.
