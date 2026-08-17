# Stop Guard Quiet Layer

Session-scoped conditions that keep the C4 premature-stop guard quiet during long-running work. Never an enforcement bypass.

## When to use

- Long-running work that no delegated step covers: emit `<<WORKFLOW_NEXT_STEP_PAUSE: {reason}>>`, then `<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>` when it ends — the marker expires 4h after it is set, but that is a backstop, so still emit the RESUME sentinel yourself.
- While `write_code`, or a step on the `hooks/lib/step-in-flight-policy.js` allow-list (`research`, `detail`, `write_tests`, `review_tests`), is in flight, C4 is already quiet — declare nothing.

Which condition silences what, and the primitive behind each: `hooks/lib/stop-exemption-policy.js` (`EXEMPTION_MATRIX`).
