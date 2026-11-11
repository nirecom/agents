# Review Criteria

Shared by every plan review format, code review, and CC fallback reviewer.

## Scope

Review only the artifact of the step under review; treat the approved upstream plan steps as premises, not targets.
Review scope and round rules: `skills/_shared/priority-hierarchy/core.md`.

## Coverage

Stay adversarial: report every concern that meets the Reporting minimum without departing from the upstream plan steps.
Round 1 is the only round that may raise new concerns; check each section of the artifact and each decision of the upstream plan steps one by one.

## Reporting minimum

State for every concern its location, the problem it causes, and a realistic path by which that problem occurs.
An available alternative alone is not a concern.
Drop any concern that misses this minimum.
Zero concerns is a valid result.

## Severity

Judge severity by the SEVERITY DEFINITION block delivered with these criteria, weighing it against the PROJECT NFR block.

## NFR compliance

Report an artifact that violates the PROJECT NFR as a concern in itself.
Never cite the NFR to drop a concern that meets the Reporting minimum.

## Neutral framing

Judge whether a choice is safe and simple enough for the requirements and constraints; never demand the best conceivable choice.

## Copies of a canonical source

Report content the artifact copies from a canonical source, such as an upstream plan step, instead of referencing it in one line; ask for a one-line reference.
A one-line reference is not a concern.
Grade a copy MEDIUM.
Exempt `## Issues` only: a script copies it verbatim and verifies the copy (`skills/_shared/no-upstream-copy.md`).

## Examples

Example blocks are stripped before delivery; never put a definition inside one.

<!-- example -->
Weighing severity by NFR: a banking project weighs security concerns more heavily.
<!-- /example -->
<!-- example -->
Threat scope: the agents repo's PROJECT_NFR assumes one user occupying one PC; extending the threat beyond that overrides the NFR and pulls excess defenses, such as encrypting every session or digital signatures, into the plan.
<!-- /example -->
<!-- example -->
Stopped progress in the agents repo: a state left only by turning the workflow off is HIGH; a state left by any other means is MEDIUM.
<!-- /example -->
<!-- example -->
Copy versus reference: "Ship the new point to production without a shadow period (details: intent)" is a correct one-line reference; before agent-plans commit a1b3adb3, the outline restated the intent's five countermeasures instead.
<!-- /example -->
