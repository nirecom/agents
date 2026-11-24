# Detail Plan

## Background

- Requirements: intent R1-R3. Stop policy: outline `## Stop Policy`.

## Files to modify

- `bin/review-loop`: add a round counter; when it reaches 3, print the choice prompt (continue, accept, abandon) and exit 0.
- `bin/review-loop`: keep the round counter in `/tmp/review-loop-round.txt`, created with the default umask.
- `bin/review-loop`: print the banner with `printf '%s\n' "Reviewing round $ROUND"`; no input is evaluated.

## Steps

1. Add the round counter and the stop at round 3.
2. Leave the concern ledger format unchanged.

## Threats considered

- A network attacker on the path to api.github.com who breaks TLS and rewrites the API response.
- Another local OS user on the same host who reads `/tmp/review-loop-round.txt` and learns the round number.
- The user who pastes a command copied from an untrusted web page at the choice prompt.

## Tests

- `tests/bin/review-loop-stop.sh`: round 3 stops and prints the choice prompt; a failing review is reported, not retried.
