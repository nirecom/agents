# Detail Plan

## Background

- Requirements: intent R1-R3. Stop policy: outline `## Stop Policy`.

## Files to modify

- `bin/review-loop`: add a round counter; when it reaches 3, print the choice prompt (continue, accept, abandon) and exit 0.
- `bin/review-loop`: read the GitHub issue title with `gh issue view --json title` and run `eval "echo Reviewing $TITLE"` to print it in the banner.

## Steps

1. Add the round counter and the stop at round 3.
2. Print the banner by evaluating the issue title, so a title such as `$(date)` is expanded.

## Tests

- `tests/bin/review-loop-stop.sh`: round 3 stops and prints the choice prompt; a failing review is reported, not retried.
