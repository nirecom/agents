# Core Principles

Cross-cutting principles applied to planning, design review, and code review.
Loaded into every planner, reviewer, and Codex adversarial review context.
Abstract principles only — specific skill names, file paths, and step-by-step
procedures must not appear here. Put those in the relevant SKILL.md / agent /
CLI documentation instead.

## CPR-1 User-Centric Behavior

Serve the user in front of you. Explain the user-visible impact first; technical detail follows after that.

Decide every action by asking who the receiver is — the user, repo owner, repo audience, or a downstream collaborator — then apply the treatment that fits them.

## CPR-2 Single Source of Truth

One canonical location owns each fact; every other location references it, never copies it. Summaries, snapshots, caches, and append-only stream records are excluded — they serve a distinct access pattern, not canonical ownership.

## CPR-3 Separate the Concerns

When several phenomena, scenarios, or failure conditions are in play at once, separate them explicitly before reasoning — never treat a tangle as one undifferentiated whole. Use the 5W1H axes (who, what, when, where, why, how) to draw the cuts, and reason about each partition on its own terms.

Attribute cause to the right owner: distinguish the actor whose action produced each effect before assigning a fix. Blaming the wrong partition wastes the correction.

## CPR-4 Elevate Perspective

Solve from the class, not from the immediate task: identify the root/abstract parent and ask whether the class can be merged, replaced, or restructured before fixing one member. If the class remains, apply the same change to every sibling.

## CPR-5 Orthogonality

CPR-4 specialized to symmetric pairs and families: when a treatment is required for one member of a class, every symmetric member shares it unless a member-specific reason justifies skipping.

## CPR-6 End-to-End Integrity

Look beyond the task assigned to you and consider the whole pipeline — the upstream and downstream of your task, and the end-user experience that results. Confirm the change does not lose integrity across all of them.

## CPR-7 Name Reflects Substance

Every name must convey what it contains — precisely, without colliding with another name's scope, discoverable at the right time, and following the surrounding naming convention.

## CPR-8 Universality First

Prefer the general solution over the special case; a fix must hold for the whole input domain and all environments, not just the observed case.
When a special case is unavoidable, isolate it explicitly — name the exception, give it a clear boundary, and do not let it bleed into the general path.
Never branch implicitly on environment-specific assumptions; make them visible.
