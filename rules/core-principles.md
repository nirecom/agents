# Core Principles

Cross-cutting principles applied to planning, design review, and code review.
Loaded into every planner, reviewer, and Codex adversarial review context.
Abstract principles only — specific skill names, file paths, and step-by-step
procedures must not appear here. Put those in the relevant SKILL.md / agent /
CLI documentation instead.

## 1. User-Centric Behavior

Serve the user in front of you, not the agent's own convenience. Decide every action by asking who the receiver is — the user, the repo audience, or a downstream collaborator — then apply the treatment that fits them.

When something goes wrong, lead with the user-visible impact (what now works, what does not, whether a workaround exists); technical detail follows only after the impact is clear.

**Anti-pattern:** Reporting technical detail first while the user still does not know whether their workflow is broken or recoverable.

## 2. Single Source of Truth

One canonical location owns each fact; every other location references it, never copies it. Summaries, snapshots, caches, and append-only stream records are excluded — they serve a distinct access pattern, not canonical ownership.

**Anti-pattern:** Restating a master's content at every reference site, letting the master and its echoes drift out of sync.

## 3. Elevate Perspective

Solve from the class, not from the immediate task: identify the root/abstract parent and ask whether the class can be merged, replaced, or restructured before fixing one member. If the class remains, apply the same change to every sibling.

**Anti-pattern:** Fixing case A while leaving symmetric cases B, C, D untouched because the user did not enumerate them — if the user has to point at each one, §3 was skipped.

## 4. Orthogonality

§3 specialized to symmetric pairs and families: when a treatment is required for one member of a class, every symmetric member shares it unless a member-specific reason justifies skipping.

**Anti-pattern:** Treating sibling members as independent when they share a contract — forgetting a counterpart is the same failure mode as §3.

## 5. Scenario Sweep

Extend §4 from current siblings to future class members: trace A → A-1, A-2, A-3 → B, B-1, B-2 and verify the fix architecture handles every projected member, or document why a member is out of scope.

**Anti-pattern:** Treating a fix as complete once current siblings are covered, without asking whether the same class of problem will recur when new members are added.

## 6. Name Reflects Substance

Every name must convey what it contains — precisely, without colliding with another name's scope, discoverable at the right time, and following the surrounding naming convention.

**Anti-pattern:** Names that swallow content from unrelated areas, or names that require reading the body to know what the file covers.
