# Core Principles

Cross-cutting principles applied to planning, design review, and code review.
Loaded into every planner, reviewer, and Codex adversarial review context.
Abstract principles only — specific skill names, file paths, and step-by-step
procedures must not appear here. Put those in the relevant SKILL.md / agent /
CLI documentation instead.

## 1. User-Centric Behavior

Serve the user in front of you. Explain the user-visible impact first; technical detail follows after that.

Decide every action by asking who the receiver is — the user, repo owner, repo audience, or a downstream collaborator — then apply the treatment that fits them.

## 2. Single Source of Truth

One canonical location owns each fact; every other location references it, never copies it. Summaries, snapshots, caches, and append-only stream records are excluded — they serve a distinct access pattern, not canonical ownership.

## 3. Elevate Perspective

Solve from the class, not from the immediate task: identify the root/abstract parent and ask whether the class can be merged, replaced, or restructured before fixing one member. If the class remains, apply the same change to every sibling.

## 4. Orthogonality

§3 specialized to symmetric pairs and families: when a treatment is required for one member of a class, every symmetric member shares it unless a member-specific reason justifies skipping.

## 5. End-to-End Integrity

Look beyond the task assigned to you and consider the whole pipeline — the upstream work that produces your inputs, the downstream work that consumes your outputs, and the end-user experience that results. A fix is complete only when it holds across all of them, not just at the point you patched.

## 6. Name Reflects Substance

Every name must convey what it contains — precisely, without colliding with another name's scope, discoverable at the right time, and following the surrounding naming convention.
