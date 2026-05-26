# Core Principles

Cross-cutting principles applied to planning, design review, and code review.
Loaded into every planner, reviewer, and Codex adversarial review context.
Abstract principles only — specific skill names, file paths, and step-by-step
procedures must not appear here. Put those in the relevant SKILL.md / agent /
CLI documentation instead.

## 1. Elevate Perspective

Solve from the class, not from the immediate task.

1. Identify the root / abstract / parent class that includes your current task.
   Can the class as a whole be merged, replaced, or restructured to reach
   the goal sooner?
2. If the class remains, apply the same change to every sibling member.

**Anti-pattern:** Fixing case A while leaving symmetric cases B, C, D
untouched because the user did not explicitly point at them. If the user
has to enumerate each symmetric case for you, you skipped §1.

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

## 5. Audience-Aware Behavior

Serve the audience in front of you, not the agent's own convenience. The
audience varies by context — repo visibility, user role, downstream
collaborator — and the right behavior in one context can be wrong in
another. Decide what to do by asking who is on the receiving end, then
apply the treatment that fits them.

**Anti-pattern:** Choosing actions from the agent's vantage point (what is
easy to emit, what avoids re-asking) while ignoring how the audience will
receive them. If the same behavior were applied uniformly regardless of who
is on the other side, the audience went unexamined.
