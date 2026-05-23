# Core Principles

Cross-cutting principles applied to planning, design review, and code review.
Loaded into every planner, reviewer, and Codex adversarial review context.
Read this at /make-outline-plan and /make-detail-plan stages, and whenever
adding or modifying a member of any class.

## 1. Elevate Perspective

Solve from the class, not from the immediate task.

1. Identify the root / abstract / parent class that includes your current task.
   Can the class as a whole be merged, replaced, or restructured to reach
   the goal sooner?
2. If the class remains, apply the same change to every sibling member.

**Anti-pattern:** Fixing case A while leaving symmetric cases B, C, D
untouched because the user did not explicitly point at them. If the user
has to enumerate each symmetric case for you, you skipped §1.

### Procedure

1. Identify the class containing the immediate task target.
2. Enumerate sibling members via `survey-code` and `survey-history` (`## Candidate class members` section).
3. Confirm the impact set in `clarify-intent` interview; record in intent.md `## Class members` with `disposition: fix in scope` or `disposition: track separately` per member.
4. SKILL machine-injects `## Class members` into outline.md and detail.md via `bin/extract-mandatory-sections` — planners must not author it.
5. Planners (`outline-planner` / `detail-planner`) MUST cover every `fix in scope` member. Reviewers (`outline-reviewer` / `detail-reviewer`) MUST verify coverage and treat un-covered members as HIGH concerns.

## 2. Orthogonality

§1 specialized to symmetric pairs / families. When a treatment is required
for one member of a class, every symmetric member shares the same treatment
unless a member-specific reason justifies skipping.

**Anti-pattern:** Treating sibling members as independent when they share a
contract. Forgetting a counterpart exists is the same failure mode as §1 —
the class went unexamined.

## 3. Name Reflects Substance

Every name must convey what it contains. A reader who sees only the
name should know what to expect and when to consult it.

1. Does the name describe the contents precisely — not more, not less?
2. Does it collide with another name's scope?
3. Will it be discovered at the right time?
4. Does it follow the surrounding naming convention?

**Anti-pattern:** Names that swallow content from unrelated areas, or
names that require reading the body to know what the file covers.

## 4. Single Source of Truth

One canonical location owns each fact. Every other location references it, not copies it.

1. Reference the master — never reproduce authoritative content; link or cite it.
2. No duplication — when the same content appears in two canonical locations, designate one as master and the other becomes a reference.
3. Extract the shared part — when two canonical locations share a section, lift it into a shared location both reference.

Summaries, snapshots, caches, and append-only stream records are excluded — they serve a distinct access pattern, not canonical ownership.

**Anti-pattern:** Restating a master's content at every reference site, so the master and its echoes drift out of sync.
