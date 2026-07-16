## Concern Identifiers

- **Round 1** — assign each concern a stable ID `C1`, `C2`, `C3`, … in order of appearance. Format: `C<N>. [<SEV>] <text>` (period after the ID).
- **Round 2+** — DO NOT introduce new concerns. Reference each prior concern by ID and report its disposition:
    - `C<N>: resolved` — the planner's revision addresses the concern.
    - `C<N>: unresolved — <one-line reason>` — the concern still applies.
  Any line not matching `^C[0-9]+:` will be mechanically discarded by the orchestrator.
- The reviewer's `Cn: resolved` / `Cn: unresolved` statement is authoritative. The orchestrator computes the residual-severity tally from your Round 2+ output.
- LOW residuals never block; MEDIUM residuals never block past Round 2; HIGH residuals at Round 2 escalate to the user.
- On Round 2+, introducing a new concern is prohibited; the orchestrator will discard it and emit a stderr warning.
