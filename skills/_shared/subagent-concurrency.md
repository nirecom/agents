# Subagent Concurrency — Shared Protocol

SSOT for whether a step's subagents run together or in sequence. Consumers add a
one-line pointer here — never restate the rule.
Worker call mechanics: `skills/_shared/worker-dispatch.md`.

## SC-P — Parallel dispatch (default)

- Independent dispatches share no read/write dependency and never write the same
  target. Shared mutable targets: same file/dir, same artifact/state path, the git
  index/tree/refs, any single external resource (issue, PR, branch, mutating endpoint).
- Unsure whether a target is shared → treat as dependent, use SC-S.
- Issue every independent dispatch in a single assistant message, as multiple tool
  calls (`run_in_background: false`); never split across turns.
- Paths must be resolved literal strings — subagents cannot expand `$VAR`.

## SC-S — Serial dispatch (state the reason)

- Serial when a later pass consumes an earlier pass's output, or two passes write
  the same target.
- Annotate with exactly this line: `Serial by dependency (SC-S): <shared state/target,
  and which pass owns it first>.` Fixed prefix — no extra fields inside the parens.
- Serial without this annotation is a defect: parallelize per SC-P or add the annotation.

## SC-W — While waiting

- Waiting on one long-running subagent MAY carry at most one line of orchestrator
  filler work — never touching state that subagent owns; only frozen inputs (config
  probes, path resolution, upstream plan artifacts).
- Never expand into a checklist or procedure; judgment stays with the orchestrator.
