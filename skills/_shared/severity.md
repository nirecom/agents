# Severity

Grade every concern, finding, and issue by the size of its impact; weigh that impact against the project's PROJECT NFR at the time of judging.
Keep this definition project-neutral: never write a project's NFR content or examples here.

## HIGH

HIGH is the same criterion as the `severity:high` label.

- A primary feature becomes unusable, or data is lost.
- Security is breached within the threat scope PROJECT_NFR assumes: a confidential-information leak, an external attack vector, or prompt injection. A threat outside that scope is not a concern.
- Progress stops with no workaround, or the change cannot be released.

An issue label needs a confirmed instance, not a theoretical or deferred risk; in a review, a concern that meets the Reporting minimum of the review criteria counts as confirmed.

## MEDIUM

A defect or omission that yields a wrong result or rework unless fixed now:

- Deterministic code logic that produces a wrong result.
- A prompt that misleads an LLM into a wrong result; LLMs include small open-weight and local models besides Anthropic models, and a prompt that misleads only non-Anthropic models is still MEDIUM.
- Progress that stops but has a workaround, at a cost in tokens and time.
- Any other loss in quality, cost, or delivery.

A requirement or NFR violation is not HIGH by itself; grade it by the impact it causes.

## LOW

Minor or latent harm:

- A code logic flaw whose effect is minor, where other logic rescues the result.
- A prompt open to misreading that misleads neither Anthropic models nor local LLMs.
- A cosmetic problem with no effect on logic.

## Labels

- HIGH maps to `severity:high`, MEDIUM to no label, LOW to `severity:low`.

## Test gaps

- A missing test takes the severity of the defect it would let through.
- Only a HIGH gap blocks `/review-tests` COMPLETE; MEDIUM and LOW gaps are advisory.
