# No Upstream Copy
<!-- lang-check: ignore — the two markers below are plan-language values that code and reviewers match. -->

Upstream means the issues (their bodies and comments, the issue snapshot) and every earlier plan step (intent, outline).

## Rule

- Never restate upstream content; reference it in one line by its section name (e.g. "See intent `## Goal`.").
- Write only what this stage newly decides or newly finds.

## Exception

- `## Issues` is carried mechanically and is the only section copied downstream.
- Write `## Accepted Tradeoffs (<stage>)` for your own stage only; never carry an upstream stage's tradeoffs. With none, write `なし` (the empty marker).
- An issue the snapshot could not fetch reads `snapshot なし (<reason>)` (the unavailable marker); a reviewer says so in one line before the verdict.

## Exit

- A copy concern is an ordinary reviewer concern; close it by accept or reject like any other (ARP-EXBG).
