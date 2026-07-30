# Subagent Concurrency — Shared Protocol

SSOT for how one skill step decides whether its subagents run together or in sequence.
Consumers reference this file with a one-line pointer; never restate the rule.
Plain-script worker call mechanics (`bin/worker-dispatch`): `skills/_shared/worker-dispatch.md`.

## SC-P — Parallel dispatch (default for independent subagents)

- Two dispatches are **independent** only when they share NO mutable effect in the step: neither reads what the other writes (read/write), AND they never write the same target (write/write).
- Shared mutable targets that make dispatches dependent: the same file or directory, the same artifact path, the same workflow state file, the git index / working tree / branch refs, and any single external resource (issue, PR, remote branch, network endpoint that mutates).
- When in doubt about a shared target, treat the dispatches as dependent and apply SC-S.
- Issue every independent dispatch in a **single assistant message** as multiple tool calls (`run_in_background: false`); a Bash gate that shares no mutable target counts as one of them.
- Never spread independent dispatches across turns — the second turn then waits on the first subagent for no dependency reason.
- Inject every path as a resolved literal string: subagents cannot expand `$VAR`.

## SC-S — Serial dispatch (requires a stated reason)

- A step is serial when a later pass consumes state an earlier pass produced, OR when two passes would write the same target (see SC-P for the shared-target list).
- Annotate every such step with exactly one line in this form, so a reader can tell an intentional dependency from a missing parallel rule:

  `Serial by dependency (SC-S): <the shared state or target, and which pass owns it first>.`

- The literal prefix `Serial by dependency (SC-S):` is fixed — do not insert extra fields inside the parentheses.
- A serial step without the annotation is a defect: either parallelize it per SC-P or add the annotation.

## SC-W — While waiting

- A step that must wait on a single long-running subagent MAY carry at most ONE line naming productive orchestrator work for that interval.
- That work MUST NOT read or write any file, artifact, or state the running subagent owns — pick work whose inputs already exist and are frozen (config probes, resolving paths, reading upstream plan artifacts).
- Never expand it into a checklist or a procedure — the orchestrator keeps its own judgment here.
