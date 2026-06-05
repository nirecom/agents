# Priority Hierarchy — Shared Protocol

Used by: `outline-planner`, `outline-reviewer`, `detail-planner`, `detail-reviewer`, and `make-detail-plan` SKILL.md.

## Ranking (most authoritative first)

`intent.md > outline.md > detail-draft.md > codex/reviewer concerns`

Upstream artifacts encode user-approved decisions; downstream artifacts/reviewers cannot override them.

## Stage-conditional scope

- Outline-stage agents: only `intent.md` is upstream-approved.
- Detail-stage agents: both `intent.md` and `outline.md` are upstream-approved.

## Planner rejection protocol

- Before accepting any reviewer concern, compare it against `## Issues`, `## Scope / Constraints`, `## Confirmed non-goals`, `## Accepted Tradeoffs`, and (detail stage) `## Adopted approach` of the upstream artifact(s).
- If the concern would require contradicting an approved decision, reject it with `reject: contradicts approved <intent|outline>` in the `ROUND_RESPONSE` trailer.
- Cite the specific upstream section being preserved (e.g., `intent.md ## Confirmed non-goals`).
- The typed form `reject: contradicts approved <intent|outline>` is a sub-form of `reject: <reason>` — use it canonically when the reason is upstream contradiction.

## Reviewer self-check

- Before emitting any concern, verify the concern does not contradict an upstream-approved decision.
- If a concern would require reopening a settled decision, suppress it and instead approve, optionally noting the gap under `## Accepted Tradeoffs` (LOW only).

## Out of scope

- Codex (OpenAI prompt; not controllable from this repo) is not bound by this rule; the planner's rejection protocol is the enforcement point.
