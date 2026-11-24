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

## Threat boundary

Version: v1

The default threat model of every review, whether or not a PROJECT NFR block is delivered; the PROJECT NFR adds to or removes from it.
Bump `Version:` with every edit that changes the meaning of this section; when the boundary pin test fails, either bump the version or update the pin.
Prefix the text of every finding, whatever its category or report format, with its threat origin (axis A), its amplifier (axis B) and its category: `axis:<A>/<B> cat:<category> <text>`, as in `N. [SEV] axis:<A>/<B> cat:<category> <text>`; a `[NOT-CONCERN]` line carries its axis tag in the form below.
The category is one word of the concern-ledger vocabulary (`skills/_shared/concern-ledger.md`); a threat finding is `security`.

| Axis A | Threat origin | Handling |
|---|---|---|
| A0 | No path: the input → agent action → harm path cannot be stated | no-path |
| A1 | External adversary, indirect: through an agent input source such as the repo, the web, a dependency or tool output (ASI01, ASI04) | in |
| A2 | External adversary, direct: attacks the host or a service over the network | out |
| A3 | User-mediated: the user's own direct prompt or command | out |
| A4 | Compromised component: memory or context poisoning (ASI06) | in |
| A5 | The agent's own malfunction: hallucination, misalignment, drift, or an artifact it writes that a trusted component later consumes (ASI10) | in |
| A6 | A human third party on the same host | out |

| Axis B (OWASP LLM06) | Amplifier | Question |
|---|---|---|
| B1 | Excessive functionality | Can the agent reach a tool beyond what the task needs? |
| B2 | Excessive permissions | Does the agent run with more permissions than the task needs? |
| B3 | Excessive autonomy | Does a high-impact action proceed without a human in the loop? |
| B0 | None of them | Every question above is no |

The boundary applies to category `security` only; every other category is tagged and reported as usual.
A security concern states its path from input through the agent's action to harm, and asks only to reduce the agent's functionality, permissions or autonomy, or to verify agent output before a trusted component consumes it; never ask for defenses against an external attacker, such as encryption.
A security finding whose origin is handled `out` or `no-path` is not a concern: write it on its own line as `[NOT-CONCERN] axis:<A>/<B> | <path>#<anchor or -> | <text>`, inside the Concern Delta section when the format has one.
Reconsider an `out` row when the PROJECT NFR states a shared host, a remotely exposed service, CI execution, or several users who can feed input; a finding the NFR brings inside the boundary stays a concern and adds `nfr:in` after its category tag, as in `axis:A2/B0 cat:security nfr:in <text>`.
When every finding is a `[NOT-CONCERN]` line, the verdict is APPROVED.

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
